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

    static func jsonString(from context: SourceContext?) -> String {
        guard let payload = bridgePayload(from: context),
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

private enum DocumentAIVerb: String {
    case develop
    case ask
    case challenge
    case define
    case rewrite

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
        case .rewrite:
            return Prompts.verbRewrite
        }
    }
}

@MainActor
final class AIMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "thinkDocument",
        "cancelDocumentAI",
        "cancelAIOperation"
    ]

    private let assetService: AssetService
    private let persistence: PersistenceService?
    private let aiOperations: AIOperationRegistry
    private let sendToWeb: (BridgeMessage) -> Void
    private let sendBridgeErrorMessage: (String, String) async -> Void
    private let isProxyUsable: () async -> Bool
    private let routeDocumentAI: (
        _ query: String,
        _ retrievalQuery: String?,
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
        self.aiOperations = container.aiOperations
        self.sendToWeb = { [bridgeService = container.bridgeService] message in
            bridgeService.send(message)
        }
        self.sendBridgeErrorMessage = { [bridgeService = container.bridgeService] type, reason in
            bridgeService.sendBridgeError(type: type, reason: reason)
        }
        self.isProxyUsable = { [deviceKeyService = container.deviceKeyService] in
            await deviceKeyService.currentState.isUsable
        }
        self.routeDocumentAI = { [orchestrator = container.orchestrator] query, retrievalQuery, queryImages, streamId, sourceScope, systemPromptOverride, onChunk, onComplete, onError, onModelSelected in
            await orchestrator.route(
                query: query,
                queryImages: queryImages,
                streamId: streamId,
                retrievalQuery: retrievalQuery,
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
        aiOperations: AIOperationRegistry = AIOperationRegistry(),
        sendToWeb: @escaping (BridgeMessage) -> Void,
        sendBridgeErrorMessage: @escaping (String, String) async -> Void = { _, _ in },
        isProxyUsable: @escaping () async -> Bool = { true },
        routeDocumentAI: @escaping (
            _ query: String,
            _ retrievalQuery: String?,
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
        self.aiOperations = aiOperations
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
            let assetService = assetService
            let imageDataURLs = await Task.detached(priority: .utility) {
                assetService.assetsToDataURLs(imageURLs)
            }.value
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
            let cleanedContext = (payload["context"]?.value as? String).flatMap(Self.cleanedDocumentContext)
            if let cleanContext = cleanedContext {
                if verb == .rewrite {
                    // Instruction-primary framing: the passage is material, the
                    // user's prompt is the task. The Ask-style "Regarding this
                    // context" wrapper demotes the instruction to a footnote.
                    resolvedQuery = "Passage:\n\"\"\"\n\(cleanContext)\n\"\"\"\n\nInstruction: \(resolvedQuery)"
                } else {
                    resolvedQuery = "Regarding this context:\n\"\"\"\n\(cleanContext)\n\"\"\"\n\n\(resolvedQuery)"
                }
            }
            let userInput = Self.userInput(selection: cleanedContext ?? query, prompt: cleanedContext == nil ? "" : query)

            var responseRaw = ""
            var selectedModel: String?
            let onChunk: (String) -> Void = { [weak self] chunk in
                guard !Task.isCancelled else { return }
                responseRaw += chunk
                self?.sendToWeb(BridgeMessage(
                    type: "documentAIChunk",
                    payload: ["requestId": AnyCodable(requestId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: (SourceContext?) -> Void = { [weak self] sourceContext in
                guard !Task.isCancelled else { return }
                if let streamId = streamIdForRAG, let persistence = self?.persistence {
                    do {
                        try persistence.saveExchange(AIExchange(
                            requestId: requestId,
                            streamId: streamId,
                            verb: verb.rawValue,
                            userInput: userInput,
                            sourceManifest: DocumentAICitationManifest.jsonString(from: sourceContext),
                            responseRaw: responseRaw,
                            model: selectedModel
                        ))
                        DebugLog.log("[AIMessageHandler] Saved exchange \(requestId)")
                    } catch {
                        DebugLog.log("[AIMessageHandler] Failed to save exchange (\(DebugLog.errorSummary(error)))")
                    }
                }
                var payload: [String: AnyCodable] = ["requestId": AnyCodable(requestId)]
                if let citations = DocumentAICitationManifest.bridgePayload(from: sourceContext) {
                    payload["citations"] = AnyCodable(citations)
                }
                if sourceContext?.mode == .retrieved {
                    payload["sourceContextMode"] = AnyCodable("retrieved")
                } else if sourceContext?.mode == .unavailable {
                    payload["sourceContextMode"] = AnyCodable("unavailable")
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
                    // Retrieval sees only the user's words; resolvedQuery's
                    // "Regarding this context:" wrapper poisons BM25 scoring.
                    cleanedContext.map { "\(query)\n\($0)" } ?? query,
                    imageDataURLs,
                    streamIdForRAG,
                    sourceScope,
                    verb.systemPrompt,
                    onChunk,
                    onComplete,
                    onError,
                    { [weak self] modelId in
                        guard !Task.isCancelled else { return }
                        selectedModel = modelId
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

        case "cancelAIOperation":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String else {
                DebugLog.log("[AIMessageHandler] Invalid cancelAIOperation payload")
                await sendBridgeErrorMessage(message.type, "Invalid cancelAIOperation payload")
                return
            }
            aiOperations.cancel(requestId)

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

    nonisolated static func cleanedDocumentContext(_ context: String) -> String? {
        let cleaned = context
            .replacingOccurrences(of: "<u>", with: "")
            .replacingOccurrences(of: "</u>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func userInput(selection: String, prompt: String) -> String {
        "Selection:\n\(selection)\n\nPrompt:\n\(prompt)"
    }
}
