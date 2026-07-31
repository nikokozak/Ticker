import Foundation

struct StreamThread: Codable, Equatable, Identifiable {
    let threadId: UUID
    let streamId: UUID
    var title: String
    var workingText: String
    let anchorText: String
    let anchorSpanId: String?
    let sourceId: UUID?
    let highlightId: UUID?
    let revision: Int
    let createdAt: Date
    let updatedAt: Date

    var id: UUID { threadId }

    init(
        threadId: UUID = UUID(),
        streamId: UUID,
        title: String = "",
        workingText: String = "",
        anchorText: String = "",
        anchorSpanId: String? = nil,
        sourceId: UUID? = nil,
        highlightId: UUID? = nil,
        revision: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.streamId = streamId
        self.title = title
        self.workingText = workingText
        self.anchorText = anchorText
        self.anchorSpanId = anchorSpanId
        self.sourceId = sourceId
        self.highlightId = highlightId
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct StreamThreadRevisionConflict: Error {
    let current: StreamThread
}

enum StreamThreadPersistenceError: LocalizedError, Equatable {
    case streamNotFound
    case threadNotFound
    case sourceOutsideStream
    case highlightOutsideSource

    var errorDescription: String? {
        switch self {
        case .streamNotFound:
            return "The Stream does not exist."
        case .threadNotFound:
            return "The thread does not exist in this Stream."
        case .sourceOutsideStream:
            return "The source does not belong to this Stream."
        case .highlightOutsideSource:
            return "The PDF highlight does not belong to this source."
        }
    }
}
