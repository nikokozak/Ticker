import Foundation

/// A local text chunk from a source document.
struct SourceChunk: Identifiable, Codable {
    let id: UUID
    let sourceId: UUID
    var seq: Int
    var text: String
    var pageStart: Int
    var pageEnd: Int
    var sectionPath: String?

    var tokenCount: Int {
        Int(ceil(Double(text.count) / 4.0))
    }

    init(
        id: UUID = UUID(),
        sourceId: UUID,
        seq: Int,
        text: String,
        pageStart: Int,
        pageEnd: Int,
        sectionPath: String? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.seq = seq
        self.text = text
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.sectionPath = sectionPath
    }
}

/// A source chunk returned from local FTS retrieval.
struct RetrievedChunk {
    let id: UUID
    let sourceId: UUID
    let sourceName: String
    let seq: Int
    let text: String
    let pageStart: Int
    let pageEnd: Int
    let sectionPath: String?
    let score: Double
}
