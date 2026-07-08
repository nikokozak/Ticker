import Foundation

/// Search combining stream-document text and local source chunk FTS matches.
final class SearchService {
    private let persistence: PersistenceService
    private let retrieval: RetrievalService

    init(
        persistence: PersistenceService,
        retrieval: RetrievalService
    ) {
        self.persistence = persistence
        self.retrieval = retrieval
    }

    // MARK: - Public Interface

    /// Perform hybrid search combining text and semantic results
    func hybridSearch(
        query: String,
        currentStreamId: UUID,
        limit: Int = 20
    ) async throws -> HybridSearchResults {
        // 1. Text search with separate limits per stream category (ensures cross-stream coverage)
        let (currentTextResults, otherTextResults) = try persistence.textSearchStreamDocuments(
            query: query,
            currentStreamId: currentStreamId,
            limitPerCategory: limit
        )

        // 2. Get current stream title for chunk results
        let currentStreamTitle = try persistence.getStreamTitle(id: currentStreamId) ?? "Untitled"

        // 3. Source chunk search in current stream.
        let chunkResults = try retrieval.retrieve(
            query: query,
            streamId: currentStreamId,
            excludeAIPrivateSources: false
        )

        // 4. Convert to unified SearchResult format, keeping results separated by stream
        var currentStreamResults: [SearchResult] = []
        var otherStreamResults: [SearchResult] = []

        // Add text results for current stream
        for textResult in currentTextResults {
            let title = extractFirstHeading(from: textResult.markdown)
                ?? textResult.streamTitle

            let snippet = extractSnippet(from: textResult.markdown, query: query)

            currentStreamResults.append(SearchResult(
                id: textResult.streamId.uuidString,
                streamId: textResult.streamId.uuidString,
                streamTitle: textResult.streamTitle,
                sourceType: .cell,
                title: title,
                shortTitle: nil,
                snippet: snippet,
                cellType: "text",
                sourceId: nil,
                sourceName: nil,
                similarity: nil,
                matchType: .text
            ))
        }

        // Add text results for other streams
        for textResult in otherTextResults {
            let title = extractFirstHeading(from: textResult.markdown)
                ?? textResult.streamTitle

            let snippet = extractSnippet(from: textResult.markdown, query: query)

            otherStreamResults.append(SearchResult(
                id: textResult.streamId.uuidString,
                streamId: textResult.streamId.uuidString,
                streamTitle: textResult.streamTitle,
                sourceType: .cell,
                title: title,
                shortTitle: nil,
                snippet: snippet,
                cellType: "text",
                sourceId: nil,
                sourceName: nil,
                similarity: nil,
                matchType: .text
            ))
        }

        // Add source chunk results (only for current stream)
        for chunkResult in chunkResults {
            let snippet = truncate(chunkResult.text, maxLength: 150)
            let shortTitle = SourceShortTitle.derive(displayName: chunkResult.sourceName)

            currentStreamResults.append(SearchResult(
                id: chunkResult.id.uuidString,
                streamId: currentStreamId.uuidString,
                streamTitle: currentStreamTitle,
                sourceType: .chunk,
                title: shortTitle,
                shortTitle: shortTitle,
                snippet: snippet,
                cellType: nil,
                sourceId: chunkResult.sourceId.uuidString,
                sourceName: chunkResult.sourceName,
                similarity: nil,
                matchType: .text
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
            // Future semantic matches first
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
        // Note: text search returns stream documents, semantic search returns chunks - these are
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

    private func extractFirstHeading(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }

            let title = trimmed
                .drop { $0 == "#" }
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !title.isEmpty {
                return truncate(title, maxLength: 80)
            }
        }
        return nil
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength - 1)
        return String(trimmed[..<endIndex]) + "…"
    }

    private func extractSnippet(from content: String, query: String, contextLength: Int = 60) -> String {
        let stripped = content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
    let shortTitle: String?
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
