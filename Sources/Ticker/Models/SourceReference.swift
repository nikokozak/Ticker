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
    var lastPageIndex: Int?
    let addedAt: Date

    var shortTitle: String {
        SourceShortTitle.derive(displayName: displayName)
    }

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
        lastPageIndex: Int? = nil,
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
        self.lastPageIndex = lastPageIndex
        self.addedAt = addedAt
    }
}

enum SourceShortTitle {
    private static let maxLength = 40

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
        return compact(title.isEmpty ? "Source" : title)
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

    /// Titles compress by shedding structure, not by chopping characters:
    /// a trailing parenthetical goes first ("(3rd Edition)"), then a subtitle
    /// after ": ", and only then the head is cut at a word boundary with an
    /// ellipsis. Middle truncation is for filenames, not titles.
    private static func compact(_ title: String) -> String {
        var result = title

        if result.count > maxLength {
            let withoutParenthetical = result
                .replacingOccurrences(of: #"\s*[(\[][^()\[\]]*[)\]]$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !withoutParenthetical.isEmpty {
                result = withoutParenthetical
            }
        }

        if result.count > maxLength,
           let head = result.components(separatedBy: ": ").first?.trimmingCharacters(in: .whitespacesAndNewlines),
           head.count >= 8 {
            result = head
        }

        if result.count > maxLength {
            let prefix = result.prefix(maxLength - 1)
            if let lastSpace = prefix.lastIndex(of: " ") {
                result = String(prefix[..<lastSpace]) + "…"
            } else {
                result = String(prefix) + "…"
            }
        }

        return result
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
