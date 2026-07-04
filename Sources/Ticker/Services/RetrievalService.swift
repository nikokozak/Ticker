import Foundation

/// Local source retrieval over the v16 FTS chunk index.
final class RetrievalService {
    private let persistence: PersistenceService

    private static let topK = 8
    private static let passthroughTokenBudget = 8_000
    // ponytail: Initial BM25 cutoff is empirical for SQLite FTS5's negative-is-better scale;
    // tune with a small golden query set before adding embeddings in R3.
    private static let bm25RelevanceCutoff = -1.0e-6

    init(persistence: PersistenceService) {
        self.persistence = persistence
    }

    /// Retrieve relevant chunks for a query within a stream.
    func retrieve(query: String, streamId: UUID) throws -> [RetrievedChunk] {
        guard let ftsQuery = Self.sanitizedFTSQuery(query) else {
            return []
        }

        let chunks = try persistence.searchSourceChunks(
            matching: ftsQuery,
            streamId: streamId,
            limit: Self.topK
        )

        guard let bestScore = chunks.first?.score,
              bestScore <= Self.bm25RelevanceCutoff else {
            return []
        }

        return chunks.filter { $0.score <= Self.bm25RelevanceCutoff }
    }

    /// One source-context decision point: small-source passthrough, retrieved manifest, or no source context.
    func assembleSourceContext(query: String, streamId: UUID) throws -> SourceContext? {
        guard let stream = try persistence.loadStream(id: streamId) else {
            return nil
        }

        let extractedTexts = stream.sources.compactMap(\.extractedText)
        let combinedText = extractedTexts.joined(separator: "\n\n---\n\n")
        let totalTokens = extractedTexts.reduce(0) { $0 + estimatedTokenCount($1) }

        // Small streams keep the exact legacy whole-text behavior. This also covers
        // pending/indexing sources while their chunks are unavailable: their extracted
        // text is still explicit local context if the whole stream fits the budget.
        if totalTokens < Self.passthroughTokenBudget && !combinedText.isEmpty {
            return SourceContext(text: combinedText, chunks: [], mode: .passthrough)
        }

        let chunks = try retrieve(query: query, streamId: streamId)
        guard !chunks.isEmpty else {
            return nil
        }

        return SourceContext(
            text: Self.buildManifest(from: chunks),
            chunks: chunks,
            mode: .retrieved
        )
    }

    /// FTS5 MATCH treats quotes/operators/parens as syntax, so raw user text is unsafe.
    /// Tokenizing to alphanumerics, quoting each token, and joining with OR gives a broad
    /// recall-first candidate set while making user punctuation inert.
    static func sanitizedFTSQuery(_ query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return nil
        }

        return Array(Set(tokens))
            .sorted()
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    static func buildManifest(from chunks: [RetrievedChunk]) -> String {
        chunks.enumerated().map { index, chunk in
            let pageText = chunk.pageStart == chunk.pageEnd
                ? "p.\(chunk.pageStart)"
                : "p.\(chunk.pageStart)–\(chunk.pageEnd)"
            let sectionText = chunk.sectionPath.map { " (§\($0))" } ?? ""
            return "[\(index + 1)] \(chunk.sourceName), \(pageText)\(sectionText):\n\(chunk.text)"
        }.joined(separator: "\n\n")
    }

    private func estimatedTokenCount(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 4.0))
    }
}

struct SourceContext {
    let text: String
    let chunks: [RetrievedChunk]
    let mode: SourceContextMode
}

enum SourceContextMode: Equatable {
    case passthrough
    case retrieved
}
