import Foundation

enum StreamThreadAnchorKind: String, Codable {
    case streamQuote = "stream_quote"
    case pdfQuote = "pdf_quote"
}

struct StreamThreadAnchor: Codable, Equatable, Identifiable {
    let anchorId: String
    let threadId: UUID
    let kind: StreamThreadAnchorKind
    let quote: String?
    let anchorSpanId: String?
    let sourceId: UUID?
    let highlightId: UUID?
    let createdAt: Date

    var id: String { anchorId }

    init(
        anchorId: String = UUID().uuidString,
        threadId: UUID,
        kind: StreamThreadAnchorKind,
        quote: String? = nil,
        anchorSpanId: String? = nil,
        sourceId: UUID? = nil,
        highlightId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.anchorId = anchorId
        self.threadId = threadId
        self.kind = kind
        self.quote = quote
        self.anchorSpanId = anchorSpanId
        self.sourceId = sourceId
        self.highlightId = highlightId
        self.createdAt = createdAt
    }
}

struct StreamThread: Codable, Equatable, Identifiable {
    let threadId: UUID
    let streamId: UUID
    var title: String
    var workingText: String
    var docJSON: String?
    var docFormatVersion: Int?
    let anchorText: String
    let anchorSpanId: String?
    let sourceId: UUID?
    let highlightId: UUID?
    // ProseMirror doc positions (opaque to Swift).
    let anchorStart: Int?
    let anchorEnd: Int?
    let detached: Bool
    let ephemeral: Bool
    let revision: Int
    let createdAt: Date
    let updatedAt: Date

    var id: UUID { threadId }

    init(
        threadId: UUID = UUID(),
        streamId: UUID,
        title: String = "",
        workingText: String = "",
        docJSON: String? = nil,
        docFormatVersion: Int? = nil,
        anchorText: String = "",
        anchorSpanId: String? = nil,
        sourceId: UUID? = nil,
        highlightId: UUID? = nil,
        anchorStart: Int? = nil,
        anchorEnd: Int? = nil,
        detached: Bool = false,
        ephemeral: Bool = false,
        revision: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.streamId = streamId
        self.title = title
        self.workingText = workingText
        self.docJSON = docJSON
        self.docFormatVersion = docFormatVersion
        self.anchorText = anchorText
        self.anchorSpanId = anchorSpanId
        self.sourceId = sourceId
        self.highlightId = highlightId
        self.anchorStart = anchorStart
        self.anchorEnd = anchorEnd
        self.detached = detached
        self.ephemeral = ephemeral
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ConversationAnchor: Codable, Equatable {
    let threadId: UUID
    // ProseMirror doc positions (opaque to Swift).
    let anchorStart: Int?
    let anchorEnd: Int?
    let anchorText: String
    let detached: Bool
    let ephemeral: Bool
    let updatedAt: Date
}

struct ConversationAnchorUpdate: Codable, Equatable {
    let threadId: UUID
    // ProseMirror doc positions (opaque to Swift).
    let anchorStart: Int
    let anchorEnd: Int
    let detached: Bool
}

struct StreamThreadRevisionConflict: Error {
    let current: StreamThread
}

enum StreamThreadPersistenceError: LocalizedError, Equatable {
    case streamNotFound
    case threadNotFound
    case sourceOutsideStream
    case highlightOutsideSource
    case anchorOutsideThread
    case invalidAnchor
    case exchangeOutsideThread
    case invalidDisposition

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
        case .anchorOutsideThread:
            return "The anchor does not belong to this conversation."
        case .invalidAnchor:
            return "The conversation anchor is invalid."
        case .exchangeOutsideThread:
            return "The AI answer does not belong to this conversation."
        case .invalidDisposition:
            return "The AI answer state is invalid."
        }
    }
}
