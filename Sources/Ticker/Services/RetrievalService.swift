import Foundation

struct PDFSectionDescriptor: Equatable {
    let streamId: UUID
    let sourceId: UUID
    let sourceName: String
    let shortTitle: String
    let sectionPath: String
    let sectionTitle: String
    let pageStart: Int
    let pageEnd: Int
}

struct PDFSectionSourceContext {
    let descriptor: PDFSectionDescriptor
    let sourceContext: SourceContext
}

enum PDFSectionContextError: LocalizedError, Equatable {
    case serviceUnavailable
    case invalidPage
    case missingSource
    case wrongStream
    case notPDF
    case sourceExcluded
    case indexing
    case noReadableText
    case indexingFailed
    case noSection
    case sectionTooLong

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "PDF section actions are unavailable right now."
        case .invalidPage:
            return "The current PDF page is unavailable."
        case .missingSource:
            return "This PDF source is no longer available."
        case .wrongStream:
            return "This PDF belongs to another stream."
        case .notPDF:
            return "Section actions require a PDF source."
        case .sourceExcluded:
            return "This source is Private for AI. Allow AI access before using section actions."
        case .indexing:
            return "This PDF is still indexing. Try the section action again shortly."
        case .noReadableText:
            return "No readable text is available for this PDF."
        case .indexingFailed:
            return "This PDF could not be indexed. Retry it from Sources."
        case .noSection:
            return "No indexed outline section is available on this page."
        case .sectionTooLong:
            return "This section is too long for one AI request."
        }
    }
}

/// Local source retrieval over the v16 FTS chunk index.
final class RetrievalService {
    private let persistence: PersistenceService
    private let embeddingProvider: EmbeddingProvider?
    private let operatingPoint: RetrievalOperatingPoint?
    private let queryBudget: TimeInterval

    private static let topK = 8
    private static let passthroughTokenBudget = 8_000
    static let maxPDFSectionReferenceTokens = LLMRequest.defaultTokenBudget - 12_000
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

    init(
        persistence: PersistenceService,
        embeddingProvider: EmbeddingProvider? = nil,
        operatingPoint: RetrievalOperatingPoint? = nil,
        queryBudget: TimeInterval = 0.1 // ponytail: hard 100ms wall; tune only from measured release telemetry.
    ) {
        self.persistence = persistence
        self.embeddingProvider = embeddingProvider
        self.operatingPoint = operatingPoint ?? RetrievalOperatingPoint.bundled()
        self.queryBudget = queryBudget
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
        let coverageTerms = applyThreshold && ftsQuery.terms.count >= 2 ? ftsQuery.terms : nil

        let chunks = try persistence.searchSourceChunks(
            matching: ftsQuery.matchExpression,
            streamId: streamId,
            limit: Self.topK,
            excludeAIPrivateSources: excludeAIPrivateSources,
            requiringAtLeastTwoOf: coverageTerms
        )

        let bm25Result: [RetrievedChunk]
        if applyThreshold {
            guard let bestScore = chunks.first?.score,
                  bestScore <= relevanceCutoff else {
                bm25Result = []
                return semanticResult(
                    query: query, streamId: streamId, bm25: bm25Result,
                    excludeAIPrivateSources: excludeAIPrivateSources
                ) ?? bm25Result
            }
            bm25Result = chunks.filter { $0.score <= relevanceCutoff }
        } else {
            bm25Result = chunks
        }

        return semanticResult(
            query: query, streamId: streamId, bm25: bm25Result,
            excludeAIPrivateSources: excludeAIPrivateSources
        ) ?? bm25Result
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
        let passthroughSources = nonPrivateSources
            .filter { $0.extractedText?.isEmpty == false }
        let extractedTexts = passthroughSources
            .compactMap(\.extractedText)
        let combinedText = extractedTexts.joined(separator: "\n\n---\n\n")
        let totalTokens = extractedTexts.reduce(0) { $0 + estimatedTokenCount($1) }

        // Small streams keep the exact legacy whole-text behavior. This also covers
        // pending/indexing sources while their chunks are unavailable: their extracted
        // text is still explicit local context if the whole stream fits the budget.
        if totalTokens < Self.passthroughTokenBudget && !combinedText.isEmpty {
            return SourceContext(
                text: combinedText,
                chunks: [],
                mode: .passthrough,
                sourceIds: passthroughSources.map(\.id)
            )
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

        let chunks = try retrieve(query: query, streamId: streamId)
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

        let candidates = try retrieve(query: query, streamId: streamId, applyThreshold: false)
        guard !candidates.isEmpty else { return nil }

        // ponytail: Single-source weak lexical matches are an intent floor; upgrade with
        // R3 golden-set embeddings before loosening the shared BM25 cutoff.
        return SourceContext(
            text: Self.buildManifest(from: candidates),
            chunks: candidates,
            mode: .retrieved
        )
    }

    func resolvePDFSection(sourceId: UUID, streamId: UUID, page: Int) throws -> PDFSectionDescriptor {
        try pdfSection(sourceId: sourceId, streamId: streamId, page: page).descriptor
    }

    func assemblePDFSectionContext(sourceId: UUID, streamId: UUID, page: Int) throws -> PDFSectionSourceContext {
        let section = try pdfSection(sourceId: sourceId, streamId: streamId, page: page)
        let chunks = section.chunks.map { chunk in
            RetrievedChunk(
                id: chunk.id,
                sourceId: chunk.sourceId,
                sourceName: section.descriptor.sourceName,
                seq: chunk.seq,
                text: chunk.text,
                pageStart: chunk.pageStart,
                pageEnd: chunk.pageEnd,
                sectionPath: chunk.sectionPath,
                score: 0
            )
        }
        let manifest = Self.buildManifest(from: chunks)
        guard LLMRequest.estimateTokens(manifest) <= Self.maxPDFSectionReferenceTokens else {
            throw PDFSectionContextError.sectionTooLong
        }

        return PDFSectionSourceContext(
            descriptor: section.descriptor,
            sourceContext: SourceContext(text: manifest, chunks: chunks, mode: .retrieved)
        )
    }

    static func reciprocalRankFuse<ID: Hashable & Comparable>(
        bm25: [ID], semantic: [ID], rrfK: Int, limit: Int
    ) -> [ID] {
        var scores: [ID: Double] = [:]
        for (offset, id) in bm25.enumerated() {
            scores[id, default: 0] += 1 / Double(rrfK + offset + 1)
        }
        for (offset, id) in semantic.enumerated() {
            scores[id, default: 0] += 1 / Double(rrfK + offset + 1)
        }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    private func semanticResult(
        query: String,
        streamId: UUID,
        bm25: [RetrievedChunk],
        excludeAIPrivateSources: Bool
    ) -> [RetrievedChunk]? {
        guard let provider = embeddingProvider, let operatingPoint else { return nil }
        do {
            let embedded = try persistence.loadChunkEmbeddings(
                streamId: streamId,
                modelId: provider.modelId,
                excludeAIPrivateSources: excludeAIPrivateSources
            )
            guard !embedded.isEmpty, let queryVector = embedQuery(query, using: provider) else { return nil }
            let semantic = embedded.compactMap { item -> (RetrievedChunk, Float)? in
                guard item.vector.count == queryVector.count else { return nil }
                let cosine = zip(queryVector, item.vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                return cosine >= operatingPoint.cosineFloor ? (item.chunk, cosine) : nil
            }.sorted {
                $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1
            }.map(\.0)
            guard !semantic.isEmpty else { return nil }
            var byId = Dictionary(uniqueKeysWithValues: bm25.map { ($0.id, $0) })
            for chunk in semantic { byId[chunk.id] = chunk }
            return Self.reciprocalRankFuse(
                bm25: bm25.map(\.id), semantic: semantic.map(\.id),
                rrfK: operatingPoint.rrfK, limit: Self.topK
            ).compactMap { byId[$0] }
        } catch {
            DebugLog.log("RetrievalService: Semantic retrieval failed (\(DebugLog.errorSummary(error)))")
            return nil
        }
    }

    private func pdfSection(
        sourceId: UUID,
        streamId: UUID,
        page: Int
    ) throws -> (descriptor: PDFSectionDescriptor, chunks: [SourceChunk]) {
        guard page > 0 else { throw PDFSectionContextError.invalidPage }
        guard let source = try persistence.loadSource(id: sourceId) else {
            throw PDFSectionContextError.missingSource
        }
        guard source.streamId == streamId else { throw PDFSectionContextError.wrongStream }
        guard source.fileType == .pdf else { throw PDFSectionContextError.notPDF }
        guard !source.aiExcluded else { throw PDFSectionContextError.sourceExcluded }

        let chunks = try persistence.loadSourceChunks(sourceId: sourceId)
        guard !chunks.isEmpty else {
            switch source.indexStatus {
            case .pending, .indexing:
                throw PDFSectionContextError.indexing
            case .failedNoText:
                throw PDFSectionContextError.noReadableText
            case .failed:
                throw PDFSectionContextError.indexingFailed
            case .ready:
                throw PDFSectionContextError.noSection
            }
        }

        guard let sectionPath = chunks.first(where: { chunk in
            chunk.pageStart <= page && page <= chunk.pageEnd && chunk.sectionPath?.isEmpty == false
        })?.sectionPath else {
            throw PDFSectionContextError.noSection
        }
        let sectionChunks = chunks.filter { $0.sectionPath == sectionPath }.sorted { $0.seq < $1.seq }
        guard let pageStart = sectionChunks.map(\.pageStart).min(),
              let pageEnd = sectionChunks.map(\.pageEnd).max() else {
            throw PDFSectionContextError.noSection
        }
        let titleCandidate = sectionPath
            .components(separatedBy: " > ")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionTitle = titleCandidate.flatMap { $0.isEmpty ? nil : $0 } ?? sectionPath

        return (
            PDFSectionDescriptor(
                streamId: streamId,
                sourceId: sourceId,
                sourceName: source.displayName,
                shortTitle: source.shortTitle,
                sectionPath: sectionPath,
                sectionTitle: sectionTitle,
                pageStart: pageStart,
                pageEnd: pageEnd
            ),
            sectionChunks
        )
    }

    private func embedQuery(_ query: String, using provider: EmbeddingProvider) -> [Float]? {
        guard provider.isReady else {
            // Never pay cold-start in the query path: this query stays BM25-only
            // while the model warms in the background for the next one.
            DebugLog.log("RetrievalService: Embedding model cold; warming in background")
            Task { _ = await provider.prepare() }
            return nil
        }
        let result = QueryEmbeddingResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            result.vector = try? await provider.embed([query]).first
        }
        guard semaphore.wait(timeout: .now() + queryBudget) == .success else {
            DebugLog.log("RetrievalService: Query embedding exceeded budget")
            return nil
        }
        return result.vector
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
            tokenCount: uniqueTokens.count,
            terms: uniqueTokens
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

private final class QueryEmbeddingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float]?
    var vector: [Float]? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct RetrievalOperatingPoint: Decodable {
    let cosineFloor: Float
    let rrfK: Int

    static func bundled() -> Self? {
        guard let url = Bundle(for: RetrievalService.self).resourceURL?
            .appendingPathComponent("Resources/retrieval-operating-point.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct SanitizedFTSQuery {
    let matchExpression: String
    let tokenCount: Int
    let terms: [String]
}

struct SourceContext {
    let text: String
    let chunks: [RetrievedChunk]
    let mode: SourceContextMode
    let sourceIds: [UUID]

    init(
        text: String,
        chunks: [RetrievedChunk],
        mode: SourceContextMode,
        sourceIds: [UUID] = []
    ) {
        self.text = text
        self.chunks = chunks
        self.mode = mode
        self.sourceIds = sourceIds
    }
}

enum SourceContextMode: Equatable {
    case passthrough
    case retrieved
    case unavailable
}

enum SourceScope: String, Codable {
    case auto
    case all
    case none
}
