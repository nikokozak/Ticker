import Foundation

final class AIMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "thinkDocument"
    ]

    private let bridgeService: BridgeService
    private let assetService: AssetService
    private let orchestrator: AIOrchestrator
    private let deviceKeyService: DeviceKeyService

    init?(container: ServiceContainer) {
        self.bridgeService = container.bridgeService
        self.assetService = container.assetService
        self.orchestrator = container.orchestrator
        self.deviceKeyService = container.deviceKeyService
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

            var streamIdForRAG: UUID? = nil

            if let streamIdValue = payload["streamId"]?.value as? String,
               let streamId = UUID(uuidString: streamIdValue) {
                streamIdForRAG = streamId
            }

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
            let onComplete: () -> Void = { [weak self] in
                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIComplete",
                    payload: ["requestId": AnyCodable(requestId)]
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
}
