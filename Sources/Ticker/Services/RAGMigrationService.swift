import Foundation

/// Retained only so old project references keep compiling while Roadmap 2 replaces the RAG path.
final class RAGMigrationService {
    init(persistence: PersistenceService, sourceService: SourceService) {
    }

    func migrateExistingSources() async {
        DebugLog.log("RAGMigration: retired; source indexing backfills lazily on stream load")
    }
}
