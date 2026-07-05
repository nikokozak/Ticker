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
    var indexStatus: SourceIndexStatus
    var aiExcluded: Bool
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
        indexStatus: SourceIndexStatus = .pending,
        aiExcluded: Bool = false,
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
        self.indexStatus = indexStatus
        self.aiExcluded = aiExcluded
        self.addedAt = addedAt
    }
}

enum SourceShortTitle {
    private static let maxLength = 24

    static func derive(displayName: String, metadataTitle: String? = nil) -> String {
        let metadataCandidate = metadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String

        if let metadataCandidate, isSaneMetadataTitle(metadataCandidate) {
            candidate = metadataCandidate
        } else {
            let stem = filenameStem(displayName)
            let firstSegment = stem.components(separatedBy: " -- ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstSegment, !firstSegment.isEmpty {
                candidate = firstSegment
            } else {
                candidate = stem
            }
        }

        let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return middleTruncate(title.isEmpty ? "Source" : title)
    }

    private static func isSaneMetadataTitle(_ title: String) -> Bool {
        guard !title.isEmpty, title.count < 80 else {
            return false
        }

        let nonWhitespace = title.filter { !$0.isWhitespace }
        return !nonWhitespace.isEmpty && !nonWhitespace.allSatisfy(\.isNumber)
    }

    private static func filenameStem(_ displayName: String) -> String {
        let lastPathComponent = (displayName as NSString).lastPathComponent
        let stem = (lastPathComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stem.isEmpty {
            return stem
        }

        return displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func middleTruncate(_ title: String) -> String {
        guard title.count > maxLength else {
            return title
        }

        let ellipsis = "..."
        let available = maxLength - ellipsis.count
        let prefixCount = Int(ceil(Double(available) / 2.0))
        let suffixCount = available - prefixCount
        return "\(title.prefix(prefixCount))\(ellipsis)\(title.suffix(suffixCount))"
    }
}

/// Status of RAG embedding for a source
enum SourceEmbeddingStatus: String, Codable {
    case none        // Not yet processed for RAG
    case processing  // Currently chunking/embedding
    case complete    // All chunks embedded
    case failed      // Embedding failed
}

/// Status of local source chunk indexing.
enum SourceIndexStatus: String, Codable {
    case pending
    case indexing
    case ready
    case failedNoText = "failed_no_text"
    case failed
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
