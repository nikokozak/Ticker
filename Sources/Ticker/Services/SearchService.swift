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

    /// Perform text search across stream documents and indexed source chunks.
    /// With no current stream (searching from the stream list) all matches land in
    /// `otherStreamResults`.
    func hybridSearch(
        query: String,
        currentStreamId: UUID?,
        limit: Int = 20
    ) async throws -> HybridSearchResults {
        // 1. Text search with separate limits per stream category (ensures cross-stream coverage)
        let (currentTextResults, otherTextResults) = try persistence.textSearchStreamDocuments(
            query: query,
            currentStreamId: currentStreamId,
            limitPerCategory: limit
        )

        // 2. Convert to unified SearchResult format, keeping results separated by stream
        var currentStreamResults = currentTextResults.map { documentResult($0, query: query) }
        var otherStreamResults = otherTextResults.map { documentResult($0, query: query) }

        // 3. Preserve hybrid retrieval for the current stream.
        if let currentStreamId {
            let currentStreamTitle = try persistence.getStreamTitle(id: currentStreamId) ?? "Untitled"
            let chunkResults = try retrieval.retrieve(
                query: query,
                streamId: currentStreamId,
                excludeAIPrivateSources: false
            )

            for chunkResult in chunkResults {
                currentStreamResults.append(self.chunkResult(
                    chunkResult,
                    streamId: currentStreamId,
                    streamTitle: currentStreamTitle
                ))
            }
        }

        // 4. Lexical source search across every other stream (or every stream
        // when Search was opened from the list).
        if let ftsQuery = RetrievalService.sanitizedFTSQuery(query) {
            let globalChunks = try persistence.searchSourceChunksGlobally(
                matching: ftsQuery.matchExpression,
                excludingStreamId: currentStreamId,
                limit: limit,
                excludeAIPrivateSources: false
            )
            otherStreamResults.append(contentsOf: globalChunks.map { match in
                chunkResult(
                    match.chunk,
                    streamId: match.streamId,
                    streamTitle: match.streamTitle
                )
            })
        }

        // 5. Deduplicate within each category.
        currentStreamResults = deduplicateResults(currentStreamResults)
        otherStreamResults = deduplicateResults(otherStreamResults)

        return HybridSearchResults(
            currentStreamResults: Array(currentStreamResults.prefix(limit)),
            otherStreamResults: Array(otherStreamResults.prefix(limit))
        )
    }

    // MARK: - Private Helpers

    private func chunkResult(
        _ chunk: RetrievedChunk,
        streamId: UUID,
        streamTitle: String
    ) -> SearchResult {
        let shortTitle = SourceShortTitle.derive(displayName: chunk.sourceName)
        return SearchResult(
            id: chunk.id.uuidString,
            streamId: streamId.uuidString,
            streamTitle: streamTitle,
            sourceType: .chunk,
            title: shortTitle,
            shortTitle: shortTitle,
            snippet: truncate(chunk.text, maxLength: 150),
            sourceId: chunk.sourceId.uuidString,
            sourceName: chunk.sourceName
        )
    }

    private func documentResult(_ textResult: StreamDocumentSearchResult, query: String) -> SearchResult {
        SearchResult(
            id: textResult.streamId.uuidString,
            streamId: textResult.streamId.uuidString,
            streamTitle: textResult.streamTitle,
            sourceType: .document,
            title: extractFirstHeading(from: textResult.markdown) ?? textResult.streamTitle,
            shortTitle: nil,
            snippet: extractSnippet(from: textResult.markdown, query: query),
            sourceId: nil,
            sourceName: nil
        )
    }

    private func deduplicateResults(_ results: [SearchResult]) -> [SearchResult] {
        // Deduplicate by streamId + sourceType + id
        // Stream documents and source chunks are different entities with different IDs.
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
    let sourceId: String?
    let sourceName: String?
}

enum SearchResultSourceType: String, Encodable {
    case document
    case chunk
}
