import Foundation

/// A reference to an external file (PDF, text, image)
struct SourceReference: Identifiable, Codable {
    let id: UUID
    let streamId: UUID
    var displayName: String
    var fileType: SourceFileType
    var bookmarkData: Data
    var originalPath: String?
    var status: SourceStatus
    var extractedText: String?
    var pageCount: Int?
    var embeddingStatus: SourceEmbeddingStatus
    let addedAt: Date

    init(
        id: UUID = UUID(),
        streamId: UUID,
        displayName: String,
        fileType: SourceFileType,
        bookmarkData: Data,
        originalPath: String? = nil,
        status: SourceStatus = .pending,
        extractedText: String? = nil,
        pageCount: Int? = nil,
        embeddingStatus: SourceEmbeddingStatus = .none,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.streamId = streamId
        self.displayName = displayName
        self.fileType = fileType
        self.bookmarkData = bookmarkData
        self.originalPath = originalPath
        self.status = status
        self.extractedText = extractedText
        self.pageCount = pageCount
        self.embeddingStatus = embeddingStatus
        self.addedAt = addedAt
    }
}

/// Status of RAG embedding for a source
enum SourceEmbeddingStatus: String, Codable {
    case none        // Not yet processed for RAG
    case processing  // Currently chunking/embedding
    case complete    // All chunks embedded
    case failed      // Embedding failed
}

/// Supported source file types
enum SourceFileType: String, Codable {
    case pdf
    case text
    case markdown
    case image

    init?(from url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            self = .pdf
        case "txt":
            self = .text
        case "md", "markdown":
            self = .markdown
        case "png", "jpg", "jpeg", "gif", "webp":
            self = .image
        default:
            return nil
        }
    }
}

/// Status of a source reference
enum SourceStatus: String, Codable {
    case pending     // Not yet processed
    case ready       // Bookmark valid, text extracted
    case stale       // File moved or deleted
    case error       // Processing failed
}
