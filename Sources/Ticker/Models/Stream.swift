import Foundation

/// A thinking session containing a Markdown document and source references.
struct Stream: Identifiable, Codable {
    let id: UUID
    var title: String
    var sources: [SourceReference]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Untitled",
        sources: [SourceReference] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Lightweight summary for list views (no cells loaded)
struct StreamSummary: Identifiable, Codable {
    let id: UUID
    let title: String
    let sourceCount: Int
    let sourceShortTitle: String?
    let cellCount: Int
    let charCount: Int
    let imageCount: Int
    let updatedAt: Date
    let previewText: String?
}

/// Canonical stream editor document (Markdown)
struct StreamDocument: Codable {
    let streamId: UUID
    var markdown: String
    var revision: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        streamId: UUID,
        markdown: String = "",
        revision: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.streamId = streamId
        self.markdown = markdown
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
