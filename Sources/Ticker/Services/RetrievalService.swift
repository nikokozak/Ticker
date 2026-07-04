import Foundation
import Accelerate

/// Retrieves relevant chunks for a query using cosine similarity
final class RetrievalService {
    private let persistence: PersistenceService
    private let embeddingService: EmbeddingService

    // MARK: - Configuration

    struct Config {
        var topK: Int = 5                    // Max chunks to retrieve
        var similarityThreshold: Float = 0.3 // Minimum similarity score
        var tokenBudget: Int = 8000          // Max tokens in retrieved context
    }

    private let config: Config

    init(
        persistence: PersistenceService,
        embeddingService: EmbeddingService,
        config: Config = Config()
    ) {
        self.persistence = persistence
        self.embeddingService = embeddingService
        self.config = config
    }

    // MARK: - Public Interface

    /// Retrieve relevant chunks for a query within a stream
    func retrieve(query: String, streamId: UUID) async throws -> [RetrievedChunk] {
        // 1. Check if embedding service is configured
        guard embeddingService.isConfigured else {
            DebugLog.log("RetrievalService: Embedding service not configured, skipping RAG")
            return []
        }

        // 2. Embed the query
        let queryEmbedding = try await embeddingService.embed(text: query)

        // 3. Get all chunks with embeddings for this stream's sources
        let candidateChunks = try persistence.loadChunksWithEmbeddings(streamId: streamId)

        guard !candidateChunks.isEmpty else {
            DebugLog.log("RetrievalService: No embedded chunks found for stream")
            return []
        }

        // 4. Calculate cosine similarity for each
        var scoredChunks: [(chunk: SourceChunk, sourceName: String, similarity: Float)] = []

        for (chunk, embedding, sourceName) in candidateChunks {
            let similarity = cosineSimilarity(queryEmbedding, embedding)
            if similarity >= config.similarityThreshold {
                scoredChunks.append((chunk, sourceName, similarity))
            }
        }

        // 5. Sort by similarity (descending)
        scoredChunks.sort { $0.similarity > $1.similarity }

        // 6. Select top-K within token budget
        var selected: [RetrievedChunk] = []
        var usedTokens = 0

        // Consider more than topK to fill budget if early chunks are small
        for (chunk, sourceName, similarity) in scoredChunks.prefix(config.topK * 2) {
            if usedTokens + chunk.tokenCount <= config.tokenBudget {
                selected.append(RetrievedChunk(
                    chunk: chunk,
                    sourceName: sourceName,
                    similarity: similarity
                ))
                usedTokens += chunk.tokenCount

                if selected.count >= config.topK {
                    break
                }
            }
        }

        DebugLog.log("RetrievalService: Retrieved \(selected.count) chunks (\(usedTokens) tokens) from \(candidateChunks.count) candidates")
        return selected
    }

    /// Build context string from retrieved chunks
    func buildContext(from chunks: [RetrievedChunk]) -> String {
        if chunks.isEmpty { return "" }

        var context = "## Relevant Excerpts from Source Documents\n\n"

        for (index, retrieved) in chunks.enumerated() {
            let chunk = retrieved.chunk
            var header = "### \(retrieved.sourceName)"

            if chunk.pageEnd != chunk.pageStart {
                header += " (pages \(chunk.pageStart)-\(chunk.pageEnd))"
            } else {
                header += " (page \(chunk.pageStart))"
            }

            context += "\(header)\n\n\(chunk.content)\n\n"

            if index < chunks.count - 1 {
                context += "---\n\n"
            }
        }

        return context
    }

    // MARK: - Private

    /// Calculate cosine similarity between two vectors using Accelerate
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        // Use Accelerate for SIMD optimization
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
}
