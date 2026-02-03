import Foundation

/// Handles migration of existing sources to the RAG pipeline
/// Processes sources that don't have embeddings yet
final class RAGMigrationService {
    private let persistence: PersistenceService
    private let sourceService: SourceService

    init(persistence: PersistenceService, sourceService: SourceService) {
        self.persistence = persistence
        self.sourceService = sourceService
    }

    /// Process all sources that don't have embeddings
    /// Should be called on app launch after a delay
    func migrateExistingSources() async {
        // Check if embedding service is configured before querying
        // This prevents infinite retry when no OpenAI key is set
        guard sourceService.isEmbeddingConfigured else {
            DebugLog.log("RAGMigration: Embedding service not configured, skipping migration")
            return
        }

        do {
            let sources = try persistence.loadSourcesNeedingEmbedding()

            guard !sources.isEmpty else {
                DebugLog.log("RAGMigration: No sources need embedding")
                return
            }

            DebugLog.log("RAGMigration: Found \(sources.count) sources to process")

            for source in sources {
                // Skip sources without extracted text
                guard source.extractedText != nil else {
                    DebugLog.log("RAGMigration: Skipping sourceId=\(source.id) - no extracted text")
                    continue
                }

                DebugLog.log("RAGMigration: Processing sourceId=\(source.id)...")
                await sourceService.processSourceForRAG(source: source)

                // Small delay between sources to avoid overwhelming the API
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
            }

            DebugLog.log("RAGMigration: Migration complete")
        } catch {
            DebugLog.log("RAGMigration: Failed to load sources (\(DebugLog.errorSummary(error)))")
        }
    }
}
