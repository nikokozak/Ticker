import Foundation

struct DocumentAICitationManifestEntry: Equatable {
    let n: Int
    let chunkId: UUID
    let sourceId: UUID
    let page: Int
    let label: String

    var bridgePayload: [String: Any] {
        [
            "n": n,
            "chunkId": chunkId.uuidString,
            "sourceId": sourceId.uuidString,
            "page": page,
            "label": label
        ]
    }
}

enum DocumentAICitationManifest {
    private static let maxSourceLabelLength = 28

    static func entries(from context: SourceContext?) -> [DocumentAICitationManifestEntry]? {
        guard let context,
              context.mode == .retrieved,
              !context.chunks.isEmpty else {
            return nil
        }

        return context.chunks.enumerated().map { index, chunk in
            DocumentAICitationManifestEntry(
                n: index + 1,
                chunkId: chunk.id,
                sourceId: chunk.sourceId,
                page: chunk.pageStart,
                label: label(sourceName: chunk.sourceName, pageStart: chunk.pageStart)
            )
        }
    }

    static func bridgePayload(from context: SourceContext?) -> [[String: Any]]? {
        entries(from: context)?.map(\.bridgePayload)
    }

    static func label(sourceName: String, pageStart: Int) -> String {
        let stripped = (sourceName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = stripped.isEmpty
            ? sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            : stripped
        let shortName = shorten(baseName.isEmpty ? "Source" : baseName)
        return "\(shortName) p.\(pageStart)"
    }

    private static func shorten(_ text: String) -> String {
        guard text.count > maxSourceLabelLength else {
            return text
        }

        let ellipsis = "..."
        let available = maxSourceLabelLength - ellipsis.count
        let prefixCount = Int(ceil(Double(available) / 2.0))
        let suffixCount = available - prefixCount
        let prefix = text.prefix(prefixCount)
        let suffix = text.suffix(suffixCount)
        return "\(prefix)\(ellipsis)\(suffix)"
    }
}

final class AIMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "thinkDocument"
    ]

    private let bridgeService: BridgeService
    private let assetService: AssetService
    private let orchestrator: AIOrchestrator
    private let deviceKeyService: DeviceKeyService
    private let persistence: PersistenceService?

    init?(container: ServiceContainer) {
        self.bridgeService = container.bridgeService
        self.assetService = container.assetService
        self.orchestrator = container.orchestrator
        self.deviceKeyService = container.deviceKeyService
        self.persistence = container.persistence
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "thinkDocument":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String,
                  let query = payload["query"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid thinkDocument payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid thinkDocument payload")
                return
            }

            let imageURLs = payload["imageURLs"]?.value as? [String] ?? []
            let imageDataURLs = assetService.assetsToDataURLs(imageURLs)
            if !imageDataURLs.isEmpty {
                DebugLog.log("ThinkDocument: Converting \(imageURLs.count) images to data URLs")
            }
            let sourceScopeRaw = payload["sourceScope"]?.value as? String
            let sourceScope = SourceScope(rawValue: sourceScopeRaw ?? "") ?? .auto

            var streamIdForRAG: UUID? = nil

            if let streamIdValue = payload["streamId"]?.value as? String,
               let streamId = UUID(uuidString: streamIdValue) {
                streamIdForRAG = streamId
            }
            let hasStreamSources = streamHasSources(streamIdForRAG)

            var resolvedQuery = query
            if let context = payload["context"]?.value as? String, !context.isEmpty {
                let cleanContext = context
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanContext.isEmpty {
                    resolvedQuery = "Regarding this context:\n\"\"\"\n\(cleanContext)\n\"\"\"\n\n\(resolvedQuery)"
                }
            }

            let onChunk: (String) -> Void = { [weak self] chunk in
                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIChunk",
                    payload: ["requestId": AnyCodable(requestId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: (SourceContext?) -> Void = { [weak self] sourceContext in
                var payload: [String: AnyCodable] = ["requestId": AnyCodable(requestId)]
                if let citations = DocumentAICitationManifest.bridgePayload(from: sourceContext) {
                    payload["citations"] = AnyCodable(citations)
                }
                if sourceContext?.mode == .retrieved {
                    payload["sourceContextMode"] = AnyCodable("retrieved")
                } else if sourceContext == nil, hasStreamSources {
                    payload["sourceContextMode"] = AnyCodable("none")
                }
                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIComplete",
                    payload: payload
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                var payload: [String: AnyCodable] = [
                    "requestId": AnyCodable(requestId),
                    "error": AnyCodable(error.localizedDescription)
                ]

                if let proxyError = error as? ProxyLLMError {
                    payload["errorCode"] = AnyCodable(proxyError.errorCode)
                    if let proxyRequestId = proxyError.requestId {
                        payload["proxyRequestId"] = AnyCodable(proxyRequestId)
                    }

                    if case .quotaExceeded(let details) = proxyError {
                        payload["quotaScope"] = AnyCodable(details.scope)
                        payload["quotaLimit"] = AnyCodable(details.limit)
                        payload["quotaUsed"] = AnyCodable(details.used)
                        payload["quotaResetAt"] = AnyCodable(details.resetAt)
                    }

                    if case .rateLimited(let retryAfter) = proxyError {
                        if let seconds = retryAfter {
                            payload["retryAfter"] = AnyCodable(seconds)
                        }
                    }
                }

                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIError",
                    payload: payload
                ))
            }

            Task { [weak self] in
                guard let self else { return }

                let proxyUsable = await self.deviceKeyService.currentState.isUsable

                guard proxyUsable else {
                    await MainActor.run {
                        onError(OrchestratorError.noProviderAvailable)
                    }
                    return
                }

                await self.orchestrator.route(
                    query: resolvedQuery,
                    queryImages: imageDataURLs,
                    streamId: streamIdForRAG,
                    sourceScope: sourceScope,
                    priorCells: [],
                    includeHeading: false,
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onError: onError,
                    onModelSelected: { [weak self] modelId in
                        self?.bridgeService.send(BridgeMessage(
                            type: "documentModelSelected",
                            payload: ["requestId": AnyCodable(requestId), "modelId": AnyCodable(modelId)]
                        ))
                    }
                )
            }

        default:
            DebugLog.log("[AIMessageHandler] Unknown message type: \(message.type)")
        }
    }

    private func streamHasSources(_ streamId: UUID?) -> Bool {
        guard let streamId, let persistence else {
            return false
        }

        do {
            return try persistence.loadStream(id: streamId)?.sources.isEmpty == false
        } catch {
            DebugLog.log("[AIMessageHandler] Failed to load stream sources (\(DebugLog.errorSummary(error)))")
            return false
        }
    }
}
