import Foundation

// MARK: - Outgoing Payloads (Swift -> JS)

/// Source added payload
struct SourceAddedPayload: Codable {
    let source: SourcePayload
}

/// Source removed payload
struct SourceRemovedPayload: Codable {
    let id: String
}

/// Image dropped payload
struct ImageDroppedPayload: Codable {
    let assetUrl: String
}

// MARK: - Nested Payloads

/// Source reference payload for bridge
struct SourcePayload: Codable {
    let id: String
    let streamId: String
    let displayName: String
    let fileType: String
    let status: String
    let extractedText: String?
    let pageCount: Int?
    let embeddingStatus: String?
    let indexStatus: String
    let addedAt: String

    init(from source: SourceReference) {
        self.id = source.id.uuidString
        self.streamId = source.streamId.uuidString
        self.displayName = source.displayName
        self.fileType = source.fileType.rawValue
        self.status = source.status.rawValue
        self.extractedText = source.extractedText
        self.pageCount = source.pageCount
        self.embeddingStatus = source.embeddingStatus.rawValue
        self.indexStatus = source.indexStatus.rawValue
        self.addedAt = ISO8601DateFormatter().string(from: source.addedAt)
    }
}

// MARK: - BridgeService Extensions

extension BridgeService {
    /// Send a typed payload to JavaScript
    func send<T: Encodable>(_ type: String, payload: T) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(payload)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DebugLog.log("[Bridge] Failed to convert payload to dict for: \(type)")
                return
            }
            let message = BridgeMessage(type: type, payload: dict.mapValues { AnyCodable($0) })
            send(message)
        } catch {
            DebugLog.log("[Bridge] Failed to encode payload for \(type) (\(DebugLog.errorSummary(error)))")
        }
    }

    // MARK: - Source Convenience Methods

    func sendSourceAdded(_ source: SourceReference) {
        send("sourceAdded", payload: SourceAddedPayload(source: SourcePayload(from: source)))
    }

    func sendSourceRemoved(id: String) {
        send("sourceRemoved", payload: SourceRemovedPayload(id: id))
    }

    // MARK: - Image Convenience Methods

    func sendImageDropped(assetUrl: String) {
        send("imageDropped", payload: ImageDroppedPayload(assetUrl: assetUrl))
    }
}
