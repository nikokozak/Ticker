import Foundation

/// A thinking session containing a Markdown document and source references.
struct Stream: Identifiable, Codable {
    let id: UUID
    var title: String
    var sources: [SourceReference]
    var sourceScope: SourceScope
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Untitled",
        sources: [SourceReference] = [],
        sourceScope: SourceScope = .auto,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sources = sources
        self.sourceScope = sourceScope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Lightweight summary for list views.
struct StreamSummary: Identifiable, Codable {
    let id: UUID
    let title: String
    let sourceCount: Int
    let sourceShortTitle: String?
    let charCount: Int
    let wordCount: Int
    let imageCount: Int
    let openQuestionCount: Int
    let updatedAt: Date
    let previewPrefix: String?
}

enum StreamTitleResolution: Equatable {
    case notFound
    case unique(UUID)
    case ambiguous
}

/// Canonical stream editor document plus its derived Markdown projection.
struct StreamDocument: Codable {
    let streamId: UUID
    var docJSON: String?
    var docFormatVersion: Int?
    var markdown: String
    var revision: Int
    var scrollOffset: Double
    let createdAt: Date
    var updatedAt: Date

    init(
        streamId: UUID,
        docJSON: String? = nil,
        docFormatVersion: Int? = nil,
        markdown: String = "",
        revision: Int = 0,
        scrollOffset: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.streamId = streamId
        self.docJSON = docJSON
        self.docFormatVersion = docFormatVersion
        self.markdown = markdown
        self.revision = revision
        self.scrollOffset = scrollOffset
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
