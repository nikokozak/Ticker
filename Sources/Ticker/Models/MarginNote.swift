import Foundation

struct MarginNote: Codable, Equatable {
    let noteId: String
    let streamId: UUID
    let anchorStart: Int
    let anchorEnd: Int
    let anchorHash: String
    let kind: String
    let body: String
    let bodyHash: String
    let requestId: String?
    let status: String
    let createdAt: Date

    init(
        noteId: String = UUID().uuidString,
        streamId: UUID,
        anchorStart: Int,
        anchorEnd: Int,
        anchorHash: String,
        kind: String,
        body: String,
        bodyHash: String,
        requestId: String? = nil,
        status: String = "open",
        createdAt: Date = Date()
    ) {
        self.noteId = noteId
        self.streamId = streamId
        self.anchorStart = anchorStart
        self.anchorEnd = anchorEnd
        self.anchorHash = anchorHash
        self.kind = kind
        self.body = body
        self.bodyHash = bodyHash
        self.requestId = requestId
        self.status = status
        self.createdAt = createdAt
    }
}
