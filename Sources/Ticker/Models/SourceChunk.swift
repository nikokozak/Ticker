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

    // ponytail: Compatibility ceiling for dormant pre-R1 retrieval code; remove when Task 1.3 rewrites retrieval over FTS.
    var chunkIndex: Int {
        get { seq }
        set { seq = newValue }
    }

    var content: String {
        get { text }
        set { text = newValue }
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

/// A retrieved chunk with relevance score for RAG queries
struct RetrievedChunk {
    let chunk: SourceChunk
    let sourceName: String
    let similarity: Float
}
