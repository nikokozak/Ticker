import Foundation

/// Hybrid search combining text matching and semantic similarity
final class SearchService {
    private let persistence: PersistenceService
    private let retrieval: RetrievalService
    private let embedding: EmbeddingService

    init(
        persistence: PersistenceService,
        retrieval: RetrievalService,
        embedding: EmbeddingService
    ) {
        self.persistence = persistence
        self.retrieval = retrieval
        self.embedding = embedding
    }

    // MARK: - Public Interface

    /// Perform hybrid search combining text and semantic results
    func hybridSearch(
        query: String,
        currentStreamId: UUID,
        limit: Int = 20
    ) async throws -> HybridSearchResults {
        // 1. Text search with separate limits per stream category (ensures cross-stream coverage)
        let (currentTextResults, otherTextResults) = try persistence.textSearchCells(
            query: query,
            currentStreamId: currentStreamId,
            limitPerCategory: limit
        )

        // 2. Get current stream title for semantic results
        let currentStreamTitle = try persistence.getStreamTitle(id: currentStreamId) ?? "Untitled"

        // 3. Semantic search in current stream (if embedding API is configured)
        // Note: Semantic search requires an API key to embed the query, even if sources
        // already have embeddings. If the key is removed, semantic search stops working.
        // This is intentional - we can't perform similarity search without embedding the query.
        var semanticResults: [RetrievedChunk] = []
        if embedding.isConfigured {
            semanticResults = try await retrieval.retrieve(query: query, streamId: currentStreamId)
        }

        // 4. Convert to unified SearchResult format, keeping results separated by stream
        var currentStreamResults: [SearchResult] = []
        var otherStreamResults: [SearchResult] = []

        // Add text results for current stream
        for textResult in currentTextResults {
            let title = textResult.blockName
                ?? extractFirstHeadingFromHtml(textResult.content)
                ?? textResult.originalPrompt
                ?? truncateHtml(textResult.content, maxLength: 50)

            let snippet = extractSnippet(from: textResult.content, query: query)

            currentStreamResults.append(SearchResult(
                id: textResult.cellId.uuidString,
                streamId: textResult.streamId.uuidString,
                streamTitle: textResult.streamTitle,
                sourceType: .cell,
                title: title,
                snippet: snippet,
                cellType: textResult.cellType,
                sourceId: nil,
                sourceName: nil,
                similarity: nil,
                matchType: .text
            ))
        }

        // Add text results for other streams
        for textResult in otherTextResults {
            let title = textResult.blockName
                ?? extractFirstHeadingFromHtml(textResult.content)
                ?? textResult.originalPrompt
                ?? truncateHtml(textResult.content, maxLength: 50)

            let snippet = extractSnippet(from: textResult.content, query: query)

            otherStreamResults.append(SearchResult(
                id: textResult.cellId.uuidString,
                streamId: textResult.streamId.uuidString,
                streamTitle: textResult.streamTitle,
                sourceType: .cell,
                title: title,
                snippet: snippet,
                cellType: textResult.cellType,
                sourceId: nil,
                sourceName: nil,
                similarity: nil,
                matchType: .text
            ))
        }

        // Add semantic results (only for current stream - from source chunks)
        for semanticResult in semanticResults {
            let snippet = truncate(semanticResult.chunk.content, maxLength: 150)

            currentStreamResults.append(SearchResult(
                id: semanticResult.chunk.id.uuidString,
                streamId: currentStreamId.uuidString,
                streamTitle: currentStreamTitle,
                sourceType: .chunk,
                title: semanticResult.sourceName,
                snippet: snippet,
                cellType: nil,
                sourceId: semanticResult.chunk.sourceId.uuidString,
                sourceName: semanticResult.sourceName,
                similarity: semanticResult.similarity,
                matchType: .semantic
            ))
        }

        // 5. Deduplicate within each category
        currentStreamResults = deduplicateResults(currentStreamResults)
        otherStreamResults = deduplicateResults(otherStreamResults)

        // 6. Sort: semantic matches first within each group, then text
        let sortedCurrent = sortResults(currentStreamResults)
        let sortedOther = sortResults(otherStreamResults)

        return HybridSearchResults(
            currentStreamResults: Array(sortedCurrent.prefix(limit)),
            otherStreamResults: Array(sortedOther.prefix(limit))
        )
    }

    // MARK: - Private Helpers

    private func sortResults(_ results: [SearchResult]) -> [SearchResult] {
        // Preserve input indices for stable tie-breaking (SQL returns by updated_at DESC)
        let indexed = results.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let (indexA, resultA) = a
            let (indexB, resultB) = b
            // Semantic matches first
            if resultA.matchType == .semantic && resultB.matchType != .semantic { return true }
            if resultA.matchType != .semantic && resultB.matchType == .semantic { return false }
            // Then by similarity if both semantic
            if let simA = resultA.similarity, let simB = resultB.similarity {
                if simA != simB { return simA > simB }
            }
            // Preserve original order (by recency from SQL) as tie-breaker
            return indexA < indexB
        }.map { $0.1 }
    }

    private func deduplicateResults(_ results: [SearchResult]) -> [SearchResult] {
        // Deduplicate by streamId + sourceType + id
        // Note: text search returns cells, semantic search returns chunks - these are
        // different entity types with different IDs, so true duplicates are rare.
        // This mainly guards against the same result appearing twice if both search
        // methods somehow return it.
        var seen = Set<String>()
        return results.filter { result in
            let key = "\(result.streamId):\(result.sourceType.rawValue):\(result.id)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func truncateHtml(_ html: String, maxLength: Int) -> String {
        // Strip HTML tags and truncate
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return truncate(stripped, maxLength: maxLength)
    }

    private func extractFirstHeadingFromHtml(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<h[1-6][^>]*>([\\s\\S]*?)</h[1-6]>", options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let innerRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let innerHtml = String(html[innerRange])
        let stripped = innerHtml
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? nil : stripped
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength - 1)
        return String(trimmed[..<endIndex]) + "…"
    }

    private func extractSnippet(from content: String, query: String, contextLength: Int = 60) -> String {
        let stripped = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find query position (case-insensitive)
        if let range = stripped.range(of: query, options: .caseInsensitive) {
            let start = stripped.distance(from: stripped.startIndex, to: range.lowerBound)
            let snippetStart = max(0, start - contextLength / 2)
            let snippetEnd = min(stripped.count, start + query.count + contextLength / 2)

            let startIndex = stripped.index(stripped.startIndex, offsetBy: snippetStart)
            let endIndex = stripped.index(stripped.startIndex, offsetBy: snippetEnd)

            var snippet = String(stripped[startIndex..<endIndex])
            if snippetStart > 0 { snippet = "…" + snippet }
            if snippetEnd < stripped.count { snippet = snippet + "…" }

            return snippet
        }

        // Fallback: just return truncated content
        return truncate(stripped, maxLength: contextLength * 2)
    }
}

// MARK: - Result Types

struct HybridSearchResults: Encodable {
    let currentStreamResults: [SearchResult]
    let otherStreamResults: [SearchResult]
}

struct SearchResult: Encodable {
    let id: String
    let streamId: String
    let streamTitle: String
    let sourceType: SearchResultSourceType
    let title: String
    let snippet: String
    let cellType: String?
    let sourceId: String?
    let sourceName: String?
    let similarity: Float?
    let matchType: SearchMatchType
}

enum SearchResultSourceType: String, Encodable {
    case cell
    case chunk
}

enum SearchMatchType: String, Encodable {
    case text
    case semantic
    case both
}
