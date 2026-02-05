import Foundation

// MARK: - Outgoing Payloads (Swift -> JS)

/// AI streaming chunk payload
struct AIChunkPayload: Codable {
    let cellId: String
    let chunk: String
}

/// AI streaming complete payload
struct AICompletePayload: Codable {
    let cellId: String
}

/// AI streaming error payload
struct AIErrorPayload: Codable {
    let cellId: String
    let error: String
}

/// Model selection payload
struct ModelSelectedPayload: Codable {
    let cellId: String
    let modelId: String
}

/// Restatement generated payload
struct RestatementPayload: Codable {
    let cellId: String
    let restatement: String
}

/// Modifier created payload
struct ModifierCreatedPayload: Codable {
    let cellId: String
    let modifier: ModifierPayload
}

/// Modifier chunk payload
struct ModifierChunkPayload: Codable {
    let cellId: String
    let chunk: String
}

/// Modifier complete payload
struct ModifierCompletePayload: Codable {
    let cellId: String
    let modifierId: String
}

/// Modifier error payload
struct ModifierErrorPayload: Codable {
    let cellId: String
    let error: String
}

/// Block refresh start payload
struct BlockRefreshStartPayload: Codable {
    let cellId: String
}

/// Block refresh chunk payload
struct BlockRefreshChunkPayload: Codable {
    let cellId: String
    let chunk: String
}

/// Block refresh complete payload
struct BlockRefreshCompletePayload: Codable {
    let cellId: String
    let content: String
}

/// Block refresh error payload
struct BlockRefreshErrorPayload: Codable {
    let cellId: String
    let error: String
}

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
        self.addedAt = ISO8601DateFormatter().string(from: source.addedAt)
    }
}

/// Modifier payload for bridge
struct ModifierPayload: Codable {
    let id: String
    let prompt: String
    let label: String?
    let createdAt: String

    init(from modifier: Modifier) {
        self.id = modifier.id.uuidString
        self.prompt = modifier.prompt
        self.label = modifier.label
        self.createdAt = ISO8601DateFormatter().string(from: modifier.createdAt)
    }

    init(id: String, prompt: String, label: String?, createdAt: String) {
        self.id = id
        self.prompt = prompt
        self.label = label
        self.createdAt = createdAt
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

    // MARK: - AI Streaming Convenience Methods

    func sendAIChunk(cellId: String, chunk: String) {
        send("aiChunk", payload: AIChunkPayload(cellId: cellId, chunk: chunk))
    }

    func sendAIComplete(cellId: String) {
        send("aiComplete", payload: AICompletePayload(cellId: cellId))
    }

    func sendAIError(cellId: String, error: String) {
        send("aiError", payload: AIErrorPayload(cellId: cellId, error: error))
    }

    func sendModelSelected(cellId: String, modelId: String) {
        send("modelSelected", payload: ModelSelectedPayload(cellId: cellId, modelId: modelId))
    }

    func sendRestatement(cellId: String, restatement: String) {
        send("restatementGenerated", payload: RestatementPayload(cellId: cellId, restatement: restatement))
    }

    // MARK: - Modifier Streaming Convenience Methods

    func sendModifierCreated(cellId: String, modifier: Modifier) {
        send("modifierCreated", payload: ModifierCreatedPayload(
            cellId: cellId,
            modifier: ModifierPayload(from: modifier)
        ))
    }

    func sendModifierChunk(cellId: String, chunk: String) {
        send("modifierChunk", payload: ModifierChunkPayload(cellId: cellId, chunk: chunk))
    }

    func sendModifierComplete(cellId: String, modifierId: String) {
        send("modifierComplete", payload: ModifierCompletePayload(cellId: cellId, modifierId: modifierId))
    }

    func sendModifierError(cellId: String, error: String) {
        send("modifierError", payload: ModifierErrorPayload(cellId: cellId, error: error))
    }

    // MARK: - Block Refresh Convenience Methods

    func sendBlockRefreshStart(cellId: String) {
        send("blockRefreshStart", payload: BlockRefreshStartPayload(cellId: cellId))
    }

    func sendBlockRefreshChunk(cellId: String, chunk: String) {
        send("blockRefreshChunk", payload: BlockRefreshChunkPayload(cellId: cellId, chunk: chunk))
    }

    func sendBlockRefreshComplete(cellId: String, content: String) {
        send("blockRefreshComplete", payload: BlockRefreshCompletePayload(cellId: cellId, content: content))
    }

    func sendBlockRefreshError(cellId: String, error: String) {
        send("blockRefreshError", payload: BlockRefreshErrorPayload(cellId: cellId, error: error))
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
