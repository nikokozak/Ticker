import Foundation

/// Local source retrieval over the v16 FTS chunk index.
final class RetrievalService {
    private let persistence: PersistenceService

    private static let topK = 8
    private static let passthroughTokenBudget = 8_000
    // ponytail: Short-query BM25 scales from a 274-page book where relevant queries scored
    // about -1.9/token and unrelated queries about -0.52/token; cap long paragraph queries
    // so strong matches around -13 remain retrievable while unrelated 8-token best -4.15 stays gated.
    private static let perTokenCutoff = -1.0
    private static let maxCutoffTokens = 8
    // ponytail: Inline English stopwords are a small guardrail for R1 BM25;
    // tune/replace with the R3 eval set before adding query-language features.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "of", "in", "on", "at", "to", "for", "with", "from", "by", "as",
        "and", "or", "not", "no", "it", "its", "this", "that", "these", "those",
        "i", "you", "he", "she", "we", "they", "what", "which", "who", "how",
        "when", "where", "why", "do", "does", "did", "can", "could", "would",
        "should", "my", "your"
    ]

    init(persistence: PersistenceService) {
        self.persistence = persistence
    }

    /// Retrieve relevant chunks for a query within a stream.
    func retrieve(
        query: String,
        streamId: UUID,
        applyThreshold: Bool = true,
        excludeAIPrivateSources: Bool = true
    ) throws -> [RetrievedChunk] {
        guard let ftsQuery = Self.sanitizedFTSQuery(query) else {
            return []
        }
        let relevanceCutoff = Self.relevanceCutoff(tokenCount: ftsQuery.tokenCount)

        let chunks = try persistence.searchSourceChunks(
            matching: ftsQuery.matchExpression,
            streamId: streamId,
            limit: Self.topK,
            excludeAIPrivateSources: excludeAIPrivateSources
        )

        guard applyThreshold else {
            return chunks
        }

        guard let bestScore = chunks.first?.score,
              bestScore <= relevanceCutoff else {
            return []
        }

        return chunks.filter { $0.score <= relevanceCutoff }
    }

    /// One source-context decision point: small-source passthrough, retrieved manifest, or no source context.
    func assembleSourceContext(query: String, streamId: UUID, scope: SourceScope = .auto) throws -> SourceContext? {
        guard scope != .none else {
            return nil
        }

        guard let stream = try persistence.loadStream(id: streamId) else {
            return nil
        }

        let nonPrivateSources = stream.sources
            .filter { !$0.aiExcluded }
        let extractedTexts = nonPrivateSources
            .compactMap(\.extractedText)
        let combinedText = extractedTexts.joined(separator: "\n\n---\n\n")
        let totalTokens = extractedTexts.reduce(0) { $0 + estimatedTokenCount($1) }

        // Small streams keep the exact legacy whole-text behavior. This also covers
        // pending/indexing sources while their chunks are unavailable: their extracted
        // text is still explicit local context if the whole stream fits the budget.
        if totalTokens < Self.passthroughTokenBudget && !combinedText.isEmpty {
            return SourceContext(text: combinedText, chunks: [], mode: .passthrough)
        }

        if scope == .all {
            let chunks = try retrieve(query: query, streamId: streamId, applyThreshold: false)
            guard !chunks.isEmpty else {
                return nil
            }

            return SourceContext(
                text: Self.buildManifest(from: chunks),
                chunks: chunks,
                mode: .retrieved
            )
        }

        let contentSourceCount = try nonPrivateSources.reduce(0) { count, source in
            if source.extractedText?.isEmpty == false {
                return count + 1
            }

            return try persistence.loadSourceChunks(sourceId: source.id).isEmpty ? count : count + 1
        }

        let candidates = try retrieve(query: query, streamId: streamId, applyThreshold: false)
        guard !candidates.isEmpty,
              let ftsQuery = Self.sanitizedFTSQuery(query) else {
            return nil
        }

        let relevanceCutoff = Self.relevanceCutoff(tokenCount: ftsQuery.tokenCount)
        let chunks = candidates.filter { $0.score <= relevanceCutoff }
        if !chunks.isEmpty {
            return SourceContext(
                text: Self.buildManifest(from: chunks),
                chunks: chunks,
                mode: .retrieved
            )
        }

        guard contentSourceCount == 1 else {
            return nil
        }

        // ponytail: Single-source weak lexical matches are an intent floor; upgrade with
        // R3 golden-set embeddings before loosening the shared BM25 cutoff.
        return SourceContext(
            text: Self.buildManifest(from: candidates),
            chunks: candidates,
            mode: .retrieved
        )
    }

    /// FTS5 MATCH treats quotes/operators/parens as syntax, so raw user text is unsafe.
    /// Tokenizing to alphanumerics, quoting each token, and joining with OR gives a broad
    /// recall-first candidate set while making user punctuation inert.
    /// Short tokens and common stopwords are dropped so unrelated questions sharing only
    /// glue words do not accidentally retrieve source chunks.
    static func sanitizedFTSQuery(_ query: String) -> SanitizedFTSQuery? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }

        guard !tokens.isEmpty else {
            return nil
        }

        let uniqueTokens = Array(Set(tokens)).sorted()
        let matchExpression = uniqueTokens
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")

        return SanitizedFTSQuery(
            matchExpression: matchExpression,
            tokenCount: uniqueTokens.count
        )
    }

    static func buildManifest(from chunks: [RetrievedChunk]) -> String {
        chunks.enumerated().map { index, chunk in
            let pageText = chunk.pageStart == chunk.pageEnd
                ? "p.\(chunk.pageStart)"
                : "p.\(chunk.pageStart)–\(chunk.pageEnd)"
            let sectionText = chunk.sectionPath.map { " (§\($0))" } ?? ""
            let sourceTitle = SourceShortTitle.derive(displayName: chunk.sourceName)
            return "[\(index + 1)] \(sourceTitle), \(pageText)\(sectionText):\n\(chunk.text)"
        }.joined(separator: "\n\n")
    }

    private func estimatedTokenCount(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 4.0))
    }

    private static func relevanceCutoff(tokenCount: Int) -> Double {
        perTokenCutoff * Double(min(tokenCount, maxCutoffTokens))
    }
}

struct SanitizedFTSQuery {
    let matchExpression: String
    let tokenCount: Int
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

enum SourceScope: String, Codable {
    case auto
    case all
    case none
}
