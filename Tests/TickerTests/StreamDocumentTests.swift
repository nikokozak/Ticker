import Foundation
import GRDB
import XCTest

@testable import Ticker

final class StreamDocumentTests: XCTestCase {
    func test_appendToStreamDocument_createsDocumentWithExactlyFragmentWhenMissing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "New Document")
            try service.saveStream(stream)

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "Captured note")

            XCTAssertEqual(result.fragment, "Captured note")
            XCTAssertTrue(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Captured note")
        }
    }

    func test_appendToStreamDocument_appendsWithBlankLineSeparatorWhenDocumentExists() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Existing Document")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "Existing markdown")

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "New fragment")

            XCTAssertEqual(result.fragment, "New fragment")
            XCTAssertFalse(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Existing markdown\n\nNew fragment")
        }
    }

    func test_appendToStreamDocument_skipsSeparatorWhenExistingDocumentIsEmpty() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Empty Existing Document")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "")

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "Only fragment")

            XCTAssertEqual(result.fragment, "Only fragment")
            XCTAssertFalse(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Only fragment")
        }
    }

    func test_appendToStreamDocument_twoSequentialAppendsPreserveOrder() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Sequential Appends")
            try service.saveStream(stream)

            let first = try service.appendToStreamDocument(streamId: stream.id, fragment: "First fragment")
            let second = try service.appendToStreamDocument(streamId: stream.id, fragment: "Second fragment")

            XCTAssertTrue(first.isNewDocument)
            XCTAssertFalse(second.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "First fragment\n\nSecond fragment")
        }
    }

    func test_loadOrCreateStreamDocumentAfterAppendReturnsMarkdownContainingFragment() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Load After Append")
            try service.saveStream(stream)

            _ = try service.appendToStreamDocument(streamId: stream.id, fragment: "Visible capture")

            let document = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertTrue(document.markdown.contains("Visible capture"))
        }
    }

    func test_appendToStreamDocument_bumpsDocumentAndStreamUpdatedAt() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Timestamp Bump")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "Before")

            let beforeDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let beforeStream = try XCTUnwrap(service.loadStream(id: stream.id))

            Thread.sleep(forTimeInterval: 0.01)

            _ = try service.appendToStreamDocument(streamId: stream.id, fragment: "After")

            let afterDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let afterStream = try XCTUnwrap(service.loadStream(id: stream.id))

            XCTAssertGreaterThan(
                afterDocument.updatedAt.timeIntervalSince1970,
                beforeDocument.updatedAt.timeIntervalSince1970
            )
            XCTAssertGreaterThan(
                afterStream.updatedAt.timeIntervalSince1970,
                beforeStream.updatedAt.timeIntervalSince1970
            )
        }
    }

    func test_textSearchFindsStreamDocumentWithSnippet() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Searchable Stream")
            try service.saveStream(stream)
            try service.saveStreamDocument(
                streamId: stream.id,
                markdown: """
                # Research Notes

                This stream document contains a retargeted search phrase for SQL coverage.

                The surrounding markdown should appear in the result snippet.
                """
            )

            let embeddingService = EmbeddingService()
            let retrievalService = RetrievalService(
                persistence: service,
                embeddingService: embeddingService
            )
            let searchService = SearchService(
                persistence: service,
                retrieval: retrievalService,
                embedding: embeddingService
            )

            let results = try await searchService.hybridSearch(
                query: "retargeted search phrase",
                currentStreamId: stream.id,
                limit: 5
            )

            let result = try XCTUnwrap(results.currentStreamResults.first)
            XCTAssertEqual(result.streamId, stream.id.uuidString)
            XCTAssertEqual(result.streamTitle, "Searchable Stream")
            XCTAssertEqual(result.sourceType.rawValue, "cell")
            XCTAssertEqual(result.cellType, "text")
            XCTAssertEqual(result.title, "Research Notes")
            XCTAssertTrue(result.snippet.contains("retargeted search phrase"))
            XCTAssertTrue(results.otherStreamResults.isEmpty)
        }
    }

    func test_v11MigrationRecoversPostDocumentQuickPanelCellsInOrder() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Recover Later Cells", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Existing document",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>First recovered note</p>",
                createdAt: documentCreatedAt + 1,
                position: 0
            )
            try insertCell(
                db,
                streamId: streamId,
                content: #"<p><img src="ticker-asset:///abc/img.png" alt="Screenshot"></p>"#,
                createdAt: documentCreatedAt + 2,
                position: 1
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            try assertPreMigrationBackupExists(nextTo: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertTrue(document.markdown.hasSuffix("""
            ## Recovered captures

            First recovered note

            ![capture](ticker-asset:///abc/img.png)
            """))
        }
    }

    func test_v11MigrationDoesNotRecoverCellsCreatedBeforeDocumentRow() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Already Seeded", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Already folded legacy note",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Already folded legacy note</p>",
                createdAt: documentCreatedAt - 1,
                position: 0
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertEqual(document.markdown, "Already folded legacy note")
        }
    }

    func test_v11MigrationDoesNotCreateDocumentForStreamsWithoutDocumentRow() throws {
        let streamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "No Document", createdAt: 900)
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Invisible capture</p>",
                createdAt: 1_001,
                position: 0
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            XCTAssertNil(try service.loadStreamDocument(streamId: streamId))
        }
    }

    func test_v11MigrationIsNoOpAfterAlreadyApplied() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "No-op", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Existing document",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Recovered once</p>",
                createdAt: documentCreatedAt + 1,
                position: 0
            )
        } body: { dbURL, fileManager in
            var firstService: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
            let firstMarkdown = try XCTUnwrap(firstService?.loadStreamDocument(streamId: streamId)).markdown
            firstService = nil

            let secondService = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
            let secondMarkdown = try XCTUnwrap(secondService.loadStreamDocument(streamId: streamId)).markdown

            XCTAssertEqual(secondMarkdown, firstMarkdown)
            XCTAssertEqual(
                secondMarkdown,
                "Existing document\n\n## Recovered captures\n\nRecovered once"
            )
        }
    }

    private func withTempPersistenceService(_ body: (PersistenceService) throws -> Void) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        defer {
            service = nil
            _ = try? fileManager.removeItem(at: tempDir)
        }

        guard let service else {
            XCTFail("Expected persistence service")
            return
        }

        try body(service)
    }

    private func withTempPersistenceService(_ body: (PersistenceService) async throws -> Void) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        defer {
            service = nil
            _ = try? fileManager.removeItem(at: tempDir)
        }

        guard let service else {
            XCTFail("Expected persistence service")
            return
        }

        try await body(service)
    }

    private func withSeededV10Database(
        seed: (Database) throws -> Void,
        body: (URL, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var dbQueue: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try dbQueue?.write { db in
            try createV10Schema(db)
            try seed(db)
            try markV10MigrationsApplied(db)
        }
        dbQueue = nil

        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        try body(dbURL, fileManager)
    }

    private func createV10Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE streams (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE cells (
                id TEXT PRIMARY KEY,
                stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'idle',
                source_binding_json TEXT,
                metadata_json TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL,
                position INTEGER NOT NULL,
                restatement TEXT,
                original_prompt TEXT,
                modifiers_json TEXT,
                versions_json TEXT,
                active_version_id TEXT,
                processing_config_json TEXT,
                references_json TEXT,
                block_name TEXT,
                source_app TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_cells_stream ON cells(stream_id)")
        try db.execute(sql: "CREATE INDEX idx_cells_position ON cells(stream_id, position)")
        try db.execute(sql: """
            CREATE TABLE stream_documents (
                stream_id TEXT PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
                markdown TEXT NOT NULL DEFAULT '',
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    }

    private func markV10MigrationsApplied(_ db: Database) throws {
        for identifier in [
            "v1_initial",
            "v2_cell_restatement",
            "v3_cell_original_prompt",
            "v4_modifier_stack",
            "v5_processing",
            "v6_fix_source_status",
            "v7_rag_pipeline",
            "v8_quick_panel",
            "v9_heading_in_content_titles",
            "v10_stream_documents"
        ] {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier]
            )
        }
    }

    private func insertStream(_ db: Database, id: UUID, title: String, createdAt: Double) throws {
        try db.execute(
            sql: """
                INSERT INTO streams (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [id.uuidString, title, createdAt, createdAt]
        )
    }

    private func insertStreamDocument(
        _ db: Database,
        streamId: UUID,
        markdown: String,
        createdAt: Double
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO stream_documents (stream_id, markdown, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [streamId.uuidString, markdown, createdAt, createdAt]
        )
    }

    private func insertCell(
        _ db: Database,
        streamId: UUID,
        content: String,
        createdAt: Double,
        position: Int
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cells (
                    id,
                    stream_id,
                    type,
                    content,
                    state,
                    metadata_json,
                    created_at,
                    updated_at,
                    position
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString,
                streamId.uuidString,
                "quote",
                content,
                "idle",
                "{}",
                createdAt,
                createdAt,
                position
            ]
        )
    }

    private func assertPreMigrationBackupExists(nextTo dbURL: URL, fileManager: FileManager) throws {
        let backupsDirectory = dbURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let backups = try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil
        )

        XCTAssertTrue(
            backups.contains { $0.pathExtension.lowercased() == "db" },
            "Expected pre-migration backup for existing DB with pending v11 migration"
        )
    }
}
