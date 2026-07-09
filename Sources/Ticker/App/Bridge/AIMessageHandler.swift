import Foundation

struct DocumentAICitationManifestEntry: Equatable {
    let n: Int
    let chunkId: UUID
    let sourceId: UUID
    let page: Int
    let shortTitle: String

    var bridgePayload: [String: Any] {
        [
            "n": n,
            "chunkId": chunkId.uuidString,
            "sourceId": sourceId.uuidString,
            "page": page,
            "shortTitle": shortTitle
        ]
    }
}

enum DocumentAICitationManifest {
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
                shortTitle: SourceShortTitle.derive(displayName: chunk.sourceName)
            )
        }
    }

    static func bridgePayload(from context: SourceContext?) -> [[String: Any]]? {
        entries(from: context)?.map(\.bridgePayload)
    }
}

private enum DocumentAIVerb: String {
    case develop
    case ask
    case challenge
    case define

    var systemPrompt: String {
        switch self {
        case .develop:
            return Prompts.verbDevelop
        case .ask:
            return Prompts.verbAsk
        case .challenge:
            return Prompts.verbChallenge
        case .define:
            return Prompts.verbDefine
        }
    }
}

final class AIMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "thinkDocument",
        "cancelDocumentAI"
    ]

    private let assetService: AssetService
    private let persistence: PersistenceService?
    private let sendToWeb: (BridgeMessage) -> Void
    private let sendBridgeErrorMessage: (String, String) async -> Void
    private let isProxyUsable: () async -> Bool
    private let routeDocumentAI: (
        _ query: String,
        _ queryImages: [String],
        _ streamId: UUID?,
        _ sourceScope: SourceScope,
        _ systemPromptOverride: String,
        _ onChunk: @escaping (String) -> Void,
        _ onComplete: @escaping (SourceContext?) -> Void,
        _ onError: @escaping (Error) -> Void,
        _ onModelSelected: ((String) -> Void)?
    ) async -> Void
    private var inFlightRequests: [String: Task<Void, Never>] = [:]

    init?(container: ServiceContainer) {
        self.assetService = container.assetService
        self.persistence = container.persistence
        self.sendToWeb = { [bridgeService = container.bridgeService] message in
            bridgeService.send(message)
        }
        self.sendBridgeErrorMessage = { [bridgeService = container.bridgeService] type, reason in
            await bridgeService.sendBridgeError(type: type, reason: reason)
        }
        self.isProxyUsable = { [deviceKeyService = container.deviceKeyService] in
            await deviceKeyService.currentState.isUsable
        }
        self.routeDocumentAI = { [orchestrator = container.orchestrator] query, queryImages, streamId, sourceScope, systemPromptOverride, onChunk, onComplete, onError, onModelSelected in
            await orchestrator.route(
                query: query,
                queryImages: queryImages,
                streamId: streamId,
                sourceScope: sourceScope,
                priorCells: [],
                systemPromptOverride: systemPromptOverride,
                includeHeading: false,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onModelSelected: onModelSelected
            )
        }
    }

    init(
        assetService: AssetService = AssetService(),
        persistence: PersistenceService? = nil,
        sendToWeb: @escaping (BridgeMessage) -> Void,
        sendBridgeErrorMessage: @escaping (String, String) async -> Void = { _, _ in },
        isProxyUsable: @escaping () async -> Bool = { true },
        routeDocumentAI: @escaping (
            _ query: String,
            _ queryImages: [String],
            _ streamId: UUID?,
            _ sourceScope: SourceScope,
            _ systemPromptOverride: String,
            _ onChunk: @escaping (String) -> Void,
            _ onComplete: @escaping (SourceContext?) -> Void,
            _ onError: @escaping (Error) -> Void,
            _ onModelSelected: ((String) -> Void)?
        ) async -> Void
    ) {
        self.assetService = assetService
        self.persistence = persistence
        self.sendToWeb = sendToWeb
        self.sendBridgeErrorMessage = sendBridgeErrorMessage
        self.isProxyUsable = isProxyUsable
        self.routeDocumentAI = routeDocumentAI
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "thinkDocument":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String,
                  let query = payload["query"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid thinkDocument payload")
                await sendBridgeErrorMessage(message.type, "Invalid thinkDocument payload")
                return
            }

            let imageURLs = payload["imageURLs"]?.value as? [String] ?? []
            let imageDataURLs = assetService.assetsToDataURLs(imageURLs)
            if !imageDataURLs.isEmpty {
                DebugLog.log("ThinkDocument: Converting \(imageURLs.count) images to data URLs")
            }
            let sourceScopeRaw = payload["sourceScope"]?.value as? String
            let sourceScope = SourceScope(rawValue: sourceScopeRaw ?? "") ?? .auto
            let verbRaw = payload["verb"]?.value as? String
            let verb = DocumentAIVerb(rawValue: verbRaw ?? "") ?? .develop

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
                guard !Task.isCancelled else { return }
                self?.sendToWeb(BridgeMessage(
                    type: "documentAIChunk",
                    payload: ["requestId": AnyCodable(requestId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: (SourceContext?) -> Void = { [weak self] sourceContext in
                guard !Task.isCancelled else { return }
                var payload: [String: AnyCodable] = ["requestId": AnyCodable(requestId)]
                if let citations = DocumentAICitationManifest.bridgePayload(from: sourceContext) {
                    payload["citations"] = AnyCodable(citations)
                }
                if sourceContext?.mode == .retrieved {
                    payload["sourceContextMode"] = AnyCodable("retrieved")
                } else if sourceContext == nil, hasStreamSources {
                    payload["sourceContextMode"] = AnyCodable("none")
                }
                self?.sendToWeb(BridgeMessage(
                    type: "documentAIComplete",
                    payload: payload
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                guard !Task.isCancelled else { return }
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

                self?.sendToWeb(BridgeMessage(
                    type: "documentAIError",
                    payload: payload
                ))
            }

            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.inFlightRequests[requestId] = nil
                }

                let proxyUsable = await self.isProxyUsable()

                guard proxyUsable else {
                    await MainActor.run {
                        onError(OrchestratorError.noProviderAvailable)
                    }
                    return
                }

                if Task.isCancelled {
                    return
                }

                await self.routeDocumentAI(
                    resolvedQuery,
                    imageDataURLs,
                    streamIdForRAG,
                    sourceScope,
                    verb.systemPrompt,
                    onChunk,
                    onComplete,
                    onError,
                    { [weak self] modelId in
                        guard !Task.isCancelled else { return }
                        self?.sendToWeb(BridgeMessage(
                            type: "documentModelSelected",
                            payload: ["requestId": AnyCodable(requestId), "modelId": AnyCodable(modelId)]
                        ))
                    }
                )
            }
            inFlightRequests[requestId] = task

        case "cancelDocumentAI":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid cancelDocumentAI payload")
                await sendBridgeErrorMessage(message.type, "Invalid cancelDocumentAI payload")
                return
            }
            inFlightRequests.removeValue(forKey: requestId)?.cancel()
            sendToWeb(BridgeMessage(
                type: "documentAIError",
                payload: [
                    "requestId": AnyCodable(requestId),
                    "error": AnyCodable("Cancelled"),
                    "errorCode": AnyCodable("cancelled")
                ]
            ))

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
