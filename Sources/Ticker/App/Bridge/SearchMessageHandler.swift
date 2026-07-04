import Foundation

final class SearchMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "hybridSearch"
    ]

    private let bridgeService: BridgeService
    private let searchService: SearchService?

    init(container: ServiceContainer) {
        self.bridgeService = container.bridgeService
        self.searchService = container.searchService
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "hybridSearch":
            guard let payload = message.payload,
                  let query = payload["query"]?.value as? String,
                  let currentStreamIdStr = payload["currentStreamId"]?.value as? String,
                  let currentStreamId = UUID(uuidString: currentStreamIdStr),
                  let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid hybridSearch payload")
                return
            }

            let limit = payload["limit"]?.value as? Int ?? 20

            guard let searchService = searchService else {
                Task { @MainActor in
                    bridgeService.respondWithError(to: callbackId, error: "Search service not available")
                }
                return
            }

            Task {
                do {
                    let results = try await searchService.hybridSearch(
                        query: query,
                        currentStreamId: currentStreamId,
                        limit: limit
                    )

                    // Encode results to JSON-compatible format
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(results)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "currentStreamResults": AnyCodable(json["currentStreamResults"]),
                            "otherStreamResults": AnyCodable(json["otherStreamResults"])
                        ])
                    }
                } catch {
                    await MainActor.run {
                        bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
                    }
                }
            }

        default:
            DebugLog.log("[SearchMessageHandler] Unknown message type: \(message.type)")
        }
    }
}
