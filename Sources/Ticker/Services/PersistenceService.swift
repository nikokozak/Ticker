import Foundation
import GRDB

/// Manages SQLite persistence for streams, cells, and sources
final class PersistenceService {
    private let dbQueue: DatabaseQueue
    private let databaseURL: URL
    private let didDatabaseExistOnInit: Bool

    private static let databaseBackupRetentionCount = 5
    private static func debugLog(_ message: String) {
#if DEBUG
        print(message)
#endif
    }

    init() throws {
        let fileManager = FileManager.default
        let databaseURL = Self.databaseURL(fileManager: fileManager)
        self.databaseURL = databaseURL
        self.didDatabaseExistOnInit = fileManager.fileExists(atPath: databaseURL.path)

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrate()
    }

    private static func databaseURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let tickerDir = appSupport.appendingPathComponent("Ticker", isDirectory: true)
        return tickerDir.appendingPathComponent("ticker.db")
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // Streams table
            try db.create(table: "streams") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Sources table
            try db.create(table: "sources") { t in
                t.column("id", .text).primaryKey()
                t.column("stream_id", .text).notNull()
                    .references("streams", onDelete: .cascade)
                t.column("display_name", .text).notNull()
                t.column("file_type", .text).notNull()
                t.column("bookmark_data", .blob).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("extracted_text", .text)
                t.column("page_count", .integer)
                t.column("added_at", .double).notNull()
            }
            try db.create(index: "idx_sources_stream", on: "sources", columns: ["stream_id"])

            // Cells table
            try db.create(table: "cells") { t in
                t.column("id", .text).primaryKey()
                t.column("stream_id", .text).notNull()
                    .references("streams", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("content", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "idle")
                t.column("source_binding_json", .text)
                t.column("metadata_json", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "idx_cells_stream", on: "cells", columns: ["stream_id"])
            try db.create(index: "idx_cells_position", on: "cells", columns: ["stream_id", "position"])
        }

        migrator.registerMigration("v2_cell_restatement") { db in
            try db.alter(table: "cells") { t in
                t.add(column: "restatement", .text)
            }
        }

        migrator.registerMigration("v3_cell_original_prompt") { db in
            try db.alter(table: "cells") { t in
                t.add(column: "original_prompt", .text)
            }
        }

        migrator.registerMigration("v4_modifier_stack") { db in
            try db.alter(table: "cells") { t in
                t.add(column: "modifiers_json", .text)
                t.add(column: "versions_json", .text)
                t.add(column: "active_version_id", .text)
            }
        }

        migrator.registerMigration("v5_processing") { db in
            try db.alter(table: "cells") { t in
                t.add(column: "processing_config_json", .text)
                t.add(column: "references_json", .text)
                t.add(column: "block_name", .text)
            }
        }

        // Fix invalid "available" status from v1_initial migration
        migrator.registerMigration("v6_fix_source_status") { db in
            try db.execute(sql: "UPDATE sources SET status = 'ready' WHERE status = 'available'")
        }

        migrator.registerMigration("v7_rag_pipeline") { db in
            // Source chunks table - stores text segments with metadata
            try db.create(table: "source_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("source_id", .text).notNull()
                    .references("sources", onDelete: .cascade)
                t.column("chunk_index", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("token_count", .integer).notNull()
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("embedding_status", .text).notNull().defaults(to: "pending")
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "idx_chunks_source", on: "source_chunks", columns: ["source_id"])
            try db.create(index: "idx_chunks_status", on: "source_chunks", columns: ["embedding_status"])

            // Chunk embeddings table - stores vector data separately
            try db.create(table: "chunk_embeddings") { t in
                t.column("chunk_id", .text).primaryKey()
                    .references("source_chunks", onDelete: .cascade)
                t.column("embedding", .blob).notNull()
                t.column("model", .text).notNull()
                t.column("created_at", .double).notNull()
            }

            // Add embedding status to sources for progress tracking
            try db.alter(table: "sources") { t in
                t.add(column: "embedding_status", .text).defaults(to: "none")
            }
        }

        migrator.registerMigration("v8_quick_panel") { db in
            // Add source_app column to cells for tracking capture source
            try db.alter(table: "cells") { t in
                t.add(column: "source_app", .text)
            }
        }

        migrator.registerMigration("v9_heading_in_content_titles") { db in
            struct TitleRow: FetchableRecord, Decodable {
                let id: String
                let content: String
                let restatement: String?
            }

            func escapeHtml(_ value: String) -> String {
                value
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "'", with: "&#39;")
            }

            func hasHeadingInContent(_ content: String) -> Bool {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                if lower.contains("<h1") || lower.contains("<h2") || lower.contains("<h3")
                    || lower.contains("<h4") || lower.contains("<h5") || lower.contains("<h6") {
                    return true
                }
                return lower.hasPrefix("# ") || lower.hasPrefix("## ") || lower.hasPrefix("### ")
            }

            let rows = try TitleRow.fetchAll(
                db,
                sql: """
                SELECT id, content, restatement
                FROM cells
                WHERE restatement IS NOT NULL AND TRIM(restatement) <> ''
                """
            )

            for row in rows {
                guard !hasHeadingInContent(row.content) else { continue }
                guard let restatement = row.restatement?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !restatement.isEmpty else { continue }

                let heading = "<h2>\(escapeHtml(restatement))</h2>"
                let newContent = heading + row.content

                try db.execute(
                    sql: "UPDATE cells SET content = ? WHERE id = ?",
                    arguments: [newContent, row.id]
                )
            }
        }

        if didDatabaseExistOnInit {
            let hasPendingMigrations = try dbQueue.read { db in
                try !migrator.hasCompletedMigrations(db)
            }
            if hasPendingMigrations {
                do {
                    try backupDatabaseBeforeMigration(retainingLast: Self.databaseBackupRetentionCount)
                } catch {
                    Self.debugLog("PersistenceService: Failed to create pre-migration DB backup (continuing): \(error)")
                }
            }
        }

        try migrator.migrate(dbQueue)
    }

    private func backupDatabaseBeforeMigration(retainingLast retentionCount: Int) throws {
        let fileManager = FileManager.default

        let backupsDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let timestamp = Self.backupTimestampFormatter.string(from: Date())
        let backupURL = backupsDirectory.appendingPathComponent("ticker-\(timestamp).db")

        // Use SQLite backup API via GRDB to avoid WAL/shm copy pitfalls.
        let backupQueue = try DatabaseQueue(path: backupURL.path)
        try dbQueue.backup(to: backupQueue)

        try rotateBackups(in: backupsDirectory, retainingLast: retentionCount)
    }

    private func rotateBackups(in directory: URL, retainingLast retentionCount: Int) throws {
        guard retentionCount > 0 else { return }

        let fileManager = FileManager.default
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let backups = candidates.filter { $0.pathExtension.lowercased() == "db" }
        guard backups.count > retentionCount else { return }

        let sortedOldestFirst = backups.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return aDate < bDate
        }

        let toDeleteCount = max(0, sortedOldestFirst.count - retentionCount)
        for url in sortedOldestFirst.prefix(toDeleteCount) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                DebugLog.log("PersistenceService: Failed to delete old DB backup (\(DebugLog.errorSummary(error)))")
            }
        }
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Stream Operations

    func loadStreamSummaries() throws -> [StreamSummary] {
        try dbQueue.read { db in
            let sql = """
                SELECT
                    s.id, s.title, s.updated_at,
                    (SELECT COUNT(*) FROM sources WHERE stream_id = s.id) as source_count,
                    (SELECT COUNT(*) FROM cells WHERE stream_id = s.id) as cell_count,
                    (SELECT content FROM cells WHERE stream_id = s.id ORDER BY position LIMIT 1) as preview_text
                FROM streams s
                ORDER BY s.updated_at DESC
            """
            return try Row.fetchAll(db, sql: sql).map { row in
                StreamSummary(
                    id: UUID(uuidString: row["id"])!,
                    title: row["title"],
                    sourceCount: row["source_count"],
                    cellCount: row["cell_count"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    previewText: row["preview_text"]
                )
            }
        }
    }

    func getStreamTitle(id: UUID) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT title FROM streams WHERE id = ?", arguments: [id.uuidString])?["title"]
        }
    }

    func loadStream(id: UUID) throws -> Stream? {
        try dbQueue.read { db in
            guard let streamRow = try Row.fetchOne(db, sql: "SELECT * FROM streams WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }

            let sourceRows = try Row.fetchAll(db, sql: "SELECT * FROM sources WHERE stream_id = ? ORDER BY added_at", arguments: [id.uuidString])
            let cellRows = try Row.fetchAll(db, sql: """
                SELECT id, stream_id, type, content, restatement, original_prompt, state, source_binding_json, metadata_json, created_at, updated_at, position, modifiers_json, versions_json, active_version_id, processing_config_json, references_json, block_name, source_app
                FROM cells
                WHERE stream_id = ?
                ORDER BY position
            """, arguments: [id.uuidString])

            let sources = sourceRows.map { row -> SourceReference in
                let embeddingStatusRaw: String? = row["embedding_status"]
                let embeddingStatus = embeddingStatusRaw.flatMap { SourceEmbeddingStatus(rawValue: $0) } ?? .none

                return SourceReference(
                    id: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    displayName: row["display_name"],
                    fileType: SourceFileType(rawValue: row["file_type"]) ?? .text,
                    bookmarkData: row["bookmark_data"],
                    status: SourceStatus(rawValue: row["status"]) ?? .pending,
                    extractedText: row["extracted_text"],
                    pageCount: row["page_count"],
                    embeddingStatus: embeddingStatus,
                    addedAt: Date(timeIntervalSince1970: row["added_at"])
                )
            }

            let cells = try cellRows.map { row -> Cell in
                var sourceBinding: SourceBinding? = nil
                if let bindingJson: String = row["source_binding_json"] {
                    sourceBinding = try JSONDecoder().decode(SourceBinding.self, from: Data(bindingJson.utf8))
                }

                let restatement: String? = row["restatement"]
                let originalPrompt: String? = row["original_prompt"]

                // Decode modifier stack fields
                var modifiers: [Modifier]? = nil
                if let modifiersJson: String = row["modifiers_json"] {
                    modifiers = try JSONDecoder().decode([Modifier].self, from: Data(modifiersJson.utf8))
                }

                var versions: [CellVersion]? = nil
                if let versionsJson: String = row["versions_json"] {
                    versions = try JSONDecoder().decode([CellVersion].self, from: Data(versionsJson.utf8))
                }

                var activeVersionId: UUID? = nil
                if let activeVersionIdStr: String = row["active_version_id"] {
                    activeVersionId = UUID(uuidString: activeVersionIdStr)
                }

                // Decode processing fields
                var processingConfig: ProcessingConfig? = nil
                if let processingConfigJson: String = row["processing_config_json"] {
                    processingConfig = try JSONDecoder().decode(ProcessingConfig.self, from: Data(processingConfigJson.utf8))
                }

                var references: [UUID]? = nil
                if let referencesJson: String = row["references_json"] {
                    references = try JSONDecoder().decode([UUID].self, from: Data(referencesJson.utf8))
                }

                let blockName: String? = row["block_name"]
                let sourceApp: String? = row["source_app"]

                return Cell(
                    id: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    content: row["content"],
                    restatement: restatement,
                    originalPrompt: originalPrompt,
                    type: CellType(rawValue: row["type"]) ?? .text,
                    sourceBinding: sourceBinding,
                    order: row["position"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    modifiers: modifiers,
                    versions: versions,
                    activeVersionId: activeVersionId,
                    processingConfig: processingConfig,
                    references: references,
                    blockName: blockName,
                    sourceApp: sourceApp
                )
            }

            return Stream(
                id: UUID(uuidString: streamRow["id"])!,
                title: streamRow["title"],
                sources: sources,
                cells: cells,
                createdAt: Date(timeIntervalSince1970: streamRow["created_at"]),
                updatedAt: Date(timeIntervalSince1970: streamRow["updated_at"])
            )
        }
    }

    func createStream(title: String) throws -> Stream {
        let stream = Stream(title: title)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO streams (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
                arguments: [stream.id.uuidString, stream.title, stream.createdAt.timeIntervalSince1970, stream.updatedAt.timeIntervalSince1970]
            )
        }
        return stream
    }

    func updateStream(_ stream: Stream) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE streams SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [stream.title, Date().timeIntervalSince1970, stream.id.uuidString]
            )
        }
    }

    func deleteStream(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM streams WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Save a new stream
    func saveStream(_ stream: Stream) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO streams (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [
                stream.id.uuidString,
                stream.title,
                stream.createdAt.timeIntervalSince1970,
                stream.updatedAt.timeIntervalSince1970
            ])
        }
    }

    /// Get the most recently modified stream ID
    func getRecentlyModifiedStreamId() throws -> UUID? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id FROM streams
                ORDER BY updated_at DESC
                LIMIT 1
            """)
            return row.flatMap { UUID(uuidString: $0["id"]) }
        }
    }

    /// Get the next cell order for a stream
    func getNextCellOrder(streamId: UUID) throws -> Int {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(MAX(position), -1) + 1 as next_order
                FROM cells
                WHERE stream_id = ?
            """, arguments: [streamId.uuidString])
            return row?["next_order"] ?? 0
        }
    }

    /// Get the insertion order for Quick Panel content
    /// Inserts before any trailing empty cell (like Notion's always-present empty block)
    /// Also bumps the order of the trailing empty cell if one exists
    func getInsertionOrderForQuickPanel(streamId: UUID) throws -> Int {
        try dbQueue.write { db in
            // Find the last cell - check if it's empty
            let lastCell = try Row.fetchOne(db, sql: """
                SELECT id, position, content
                FROM cells
                WHERE stream_id = ?
                ORDER BY position DESC
                LIMIT 1
            """, arguments: [streamId.uuidString])

            guard let lastCell = lastCell else {
                // No cells - start at 0
                return 0
            }

            let lastContent = lastCell["content"] as? String ?? ""
            let lastOrder = lastCell["position"] as? Int ?? 0

            // Check if last cell is empty (no content or just empty HTML tags)
            let trimmedContent = lastContent
                .replacingOccurrences(of: "<p>", with: "")
                .replacingOccurrences(of: "</p>", with: "")
                .replacingOccurrences(of: "<br>", with: "")
                .replacingOccurrences(of: "&nbsp;", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedContent.isEmpty {
                // Last cell is empty - bump its order and insert at its old position
                let lastCellId = lastCell["id"] as? String ?? ""
                try db.execute(sql: """
                    UPDATE cells SET position = position + 10 WHERE id = ?
                """, arguments: [lastCellId])
                return lastOrder
            } else {
                // Last cell has content - insert after it
                return lastOrder + 1
            }
        }
    }

    // MARK: - Cell Operations

    func saveCell(_ cell: Cell) throws {
        try dbQueue.write { db in
            let bindingJson: String?
            if let binding = cell.sourceBinding {
                bindingJson = String(data: try JSONEncoder().encode(binding), encoding: .utf8)
            } else {
                bindingJson = nil
            }

            let metadataJson = "{}"  // Simplified for now

            // Encode modifier stack fields
            let modifiersJson: String?
            if let modifiers = cell.modifiers {
                modifiersJson = String(data: try JSONEncoder().encode(modifiers), encoding: .utf8)
            } else {
                modifiersJson = nil
            }

            let versionsJson: String?
            if let versions = cell.versions {
                versionsJson = String(data: try JSONEncoder().encode(versions), encoding: .utf8)
            } else {
                versionsJson = nil
            }

            let activeVersionIdStr = cell.activeVersionId?.uuidString

            // Encode processing fields
            let processingConfigJson: String?
            if let processingConfig = cell.processingConfig {
                processingConfigJson = String(data: try JSONEncoder().encode(processingConfig), encoding: .utf8)
            } else {
                processingConfigJson = nil
            }

            let referencesJson: String?
            if let references = cell.references {
                referencesJson = String(data: try JSONEncoder().encode(references), encoding: .utf8)
            } else {
                referencesJson = nil
            }

            try db.execute(
                sql: """
                    INSERT INTO cells (id, stream_id, type, content, restatement, original_prompt, state, source_binding_json, metadata_json, created_at, updated_at, position, modifiers_json, versions_json, active_version_id, processing_config_json, references_json, block_name, source_app)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content,
                        restatement = excluded.restatement,
                        original_prompt = CASE
                            WHEN excluded.type = 'aiResponse' AND excluded.original_prompt IS NULL
                            THEN cells.original_prompt
                            ELSE excluded.original_prompt
                        END,
                        type = excluded.type,
                        state = excluded.state,
                        source_binding_json = excluded.source_binding_json,
                        updated_at = excluded.updated_at,
                        position = excluded.position,
                        modifiers_json = excluded.modifiers_json,
                        versions_json = excluded.versions_json,
                        active_version_id = excluded.active_version_id,
                        processing_config_json = excluded.processing_config_json,
                        references_json = excluded.references_json,
                        block_name = excluded.block_name,
                        source_app = excluded.source_app
                """,
                arguments: [
                    cell.id.uuidString,
                    cell.streamId.uuidString,
                    cell.type.rawValue,
                    cell.content,
                    cell.restatement,
                    cell.originalPrompt,
                    "idle",
                    bindingJson,
                    metadataJson,
                    cell.createdAt.timeIntervalSince1970,
                    cell.updatedAt.timeIntervalSince1970,
                    cell.order,
                    modifiersJson,
                    versionsJson,
                    activeVersionIdStr,
                    processingConfigJson,
                    referencesJson,
                    cell.blockName,
                    cell.sourceApp
                ]
            )

            // Update stream's updated_at
            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, cell.streamId.uuidString]
            )
        }
    }

    /// Fetch a single cell's content by ID (used for asset cleanup)
    func getCellContent(id: UUID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM cells WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func deleteCell(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cells WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Update cell positions in bulk (for drag/drop reordering)
    func updateCellOrders(_ orders: [(id: UUID, order: Int)], streamId: UUID) throws {
        let now = Date().timeIntervalSince1970
        try dbQueue.write { db in
            for (id, order) in orders {
                try db.execute(
                    sql: "UPDATE cells SET position = ?, updated_at = ? WHERE id = ?",
                    arguments: [order, now, id.uuidString]
                )
            }
            // Also update stream's updated_at
            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [now, streamId.uuidString]
            )
        }
    }

    /// Update a cell's restatement
    func updateCellRestatement(cellId: UUID, restatement: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE cells SET restatement = ?, updated_at = ? WHERE id = ?",
                arguments: [restatement, Date().timeIntervalSince1970, cellId.uuidString]
            )
        }
    }

    // MARK: - Source Operations

    func saveSource(_ source: SourceReference) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sources (id, stream_id, display_name, file_type, bookmark_data, status, extracted_text, page_count, added_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        status = excluded.status,
                        extracted_text = excluded.extracted_text,
                        page_count = excluded.page_count
                """,
                arguments: [
                    source.id.uuidString,
                    source.streamId.uuidString,
                    source.displayName,
                    source.fileType.rawValue,
                    source.bookmarkData,
                    source.status.rawValue,
                    source.extractedText,
                    source.pageCount,
                    source.addedAt.timeIntervalSince1970
                ]
            )

            // Update stream's updated_at
            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, source.streamId.uuidString]
            )
        }
    }

    func deleteSource(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Chunk Operations (RAG Pipeline)

    func saveChunks(_ chunks: [SourceChunk]) throws {
        try dbQueue.write { db in
            for chunk in chunks {
                try db.execute(
                    sql: """
                        INSERT INTO source_chunks (id, source_id, chunk_index, content, token_count, page_start, page_end, embedding_status, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            content = excluded.content,
                            token_count = excluded.token_count,
                            embedding_status = excluded.embedding_status
                    """,
                    arguments: [
                        chunk.id.uuidString,
                        chunk.sourceId.uuidString,
                        chunk.chunkIndex,
                        chunk.content,
                        chunk.tokenCount,
                        chunk.pageStart,
                        chunk.pageEnd,
                        chunk.embeddingStatus.rawValue,
                        chunk.createdAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    func saveEmbedding(chunkId: UUID, embedding: [Float], model: String) throws {
        let blob = EmbeddingService.toBlob(embedding)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chunk_embeddings (chunk_id, embedding, model, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(chunk_id) DO UPDATE SET
                        embedding = excluded.embedding,
                        model = excluded.model,
                        created_at = excluded.created_at
                """,
                arguments: [
                    chunkId.uuidString,
                    blob,
                    model,
                    Date().timeIntervalSince1970
                ]
            )

            // Update chunk status to complete
            try db.execute(
                sql: "UPDATE source_chunks SET embedding_status = ? WHERE id = ?",
                arguments: [EmbeddingStatus.complete.rawValue, chunkId.uuidString]
            )
        }
    }

    func loadChunksWithEmbeddings(streamId: UUID) throws -> [(SourceChunk, [Float], String)] {
        try dbQueue.read { db in
            let sql = """
                SELECT c.*, e.embedding, s.display_name
                FROM source_chunks c
                JOIN chunk_embeddings e ON c.id = e.chunk_id
                JOIN sources s ON c.source_id = s.id
                WHERE s.stream_id = ?
                ORDER BY c.source_id, c.chunk_index
            """

            return try Row.fetchAll(db, sql: sql, arguments: [streamId.uuidString]).map { row in
                let chunk = SourceChunk(
                    id: UUID(uuidString: row["id"])!,
                    sourceId: UUID(uuidString: row["source_id"])!,
                    chunkIndex: row["chunk_index"],
                    content: row["content"],
                    tokenCount: row["token_count"],
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    embeddingStatus: EmbeddingStatus(rawValue: row["embedding_status"]) ?? .complete,
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                )
                let embeddingData: Data = row["embedding"]
                let embedding = EmbeddingService.fromBlob(embeddingData)
                let sourceName: String = row["display_name"]
                return (chunk, embedding, sourceName)
            }
        }
    }

    func loadPendingChunks(limit: Int = 100) throws -> [SourceChunk] {
        try dbQueue.read { db in
            let sql = """
                SELECT * FROM source_chunks
                WHERE embedding_status = 'pending'
                ORDER BY created_at
                LIMIT ?
            """
            return try Row.fetchAll(db, sql: sql, arguments: [limit]).map { row in
                SourceChunk(
                    id: UUID(uuidString: row["id"])!,
                    sourceId: UUID(uuidString: row["source_id"])!,
                    chunkIndex: row["chunk_index"],
                    content: row["content"],
                    tokenCount: row["token_count"],
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    embeddingStatus: .pending,
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                )
            }
        }
    }

    func updateSourceEmbeddingStatus(_ sourceId: UUID, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sources SET embedding_status = ? WHERE id = ?",
                arguments: [status, sourceId.uuidString]
            )
        }
    }

    func loadSourcesNeedingEmbedding() throws -> [SourceReference] {
        try dbQueue.read { db in
            let sql = """
                SELECT * FROM sources
                WHERE embedding_status = 'none' OR embedding_status IS NULL
                ORDER BY added_at
            """
            return try Row.fetchAll(db, sql: sql).map { row in
                SourceReference(
                    id: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    displayName: row["display_name"],
                    fileType: SourceFileType(rawValue: row["file_type"]) ?? .text,
                    bookmarkData: row["bookmark_data"],
                    status: SourceStatus(rawValue: row["status"]) ?? .pending,
                    extractedText: row["extracted_text"],
                    pageCount: row["page_count"],
                    addedAt: Date(timeIntervalSince1970: row["added_at"])
                )
            }
        }
    }

    func deleteChunksForSource(_ sourceId: UUID) throws {
        try dbQueue.write { db in
            // CASCADE handles chunk_embeddings automatically
            try db.execute(
                sql: "DELETE FROM source_chunks WHERE source_id = ?",
                arguments: [sourceId.uuidString]
            )
        }
    }

    // MARK: - Text Search

    /// Search cells by text, returning results split by current vs other streams.
    /// Each stream category gets its own limit to ensure cross-stream coverage.
    /// Searches across content, originalPrompt, restatement, and blockName fields.
    func textSearchCells(
        query: String,
        currentStreamId: UUID,
        limitPerCategory: Int = 15
    ) throws -> (currentStream: [CellSearchResult], otherStreams: [CellSearchResult]) {
        // Escape SQL LIKE special characters to prevent injection
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        return try dbQueue.read { db in
            // Search current stream
            let currentResults = try Row.fetchAll(db, sql: """
                SELECT c.id, c.stream_id, s.title as stream_title,
                       c.content, c.type, c.restatement, c.original_prompt, c.block_name
                FROM cells c
                JOIN streams s ON c.stream_id = s.id
                WHERE c.stream_id = ?
                  AND (c.content LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.original_prompt LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.restatement LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.block_name LIKE ? ESCAPE '\\' COLLATE NOCASE)
                ORDER BY c.updated_at DESC
                LIMIT ?
            """, arguments: [currentStreamId.uuidString, pattern, pattern, pattern, pattern, limitPerCategory])
            .map { row in
                CellSearchResult(
                    cellId: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    streamTitle: row["stream_title"],
                    content: row["content"],
                    cellType: row["type"],
                    restatement: row["restatement"],
                    originalPrompt: row["original_prompt"],
                    blockName: row["block_name"]
                )
            }

            // Search other streams
            let otherResults = try Row.fetchAll(db, sql: """
                SELECT c.id, c.stream_id, s.title as stream_title,
                       c.content, c.type, c.restatement, c.original_prompt, c.block_name
                FROM cells c
                JOIN streams s ON c.stream_id = s.id
                WHERE c.stream_id != ?
                  AND (c.content LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.original_prompt LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.restatement LIKE ? ESCAPE '\\' COLLATE NOCASE
                       OR c.block_name LIKE ? ESCAPE '\\' COLLATE NOCASE)
                ORDER BY c.updated_at DESC
                LIMIT ?
            """, arguments: [currentStreamId.uuidString, pattern, pattern, pattern, pattern, limitPerCategory])
            .map { row in
                CellSearchResult(
                    cellId: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    streamTitle: row["stream_title"],
                    content: row["content"],
                    cellType: row["type"],
                    restatement: row["restatement"],
                    originalPrompt: row["original_prompt"],
                    blockName: row["block_name"]
                )
            }

            return (currentResults, otherResults)
        }
    }
}

/// Result from text search on cells
struct CellSearchResult {
    let cellId: UUID
    let streamId: UUID
    let streamTitle: String
    let content: String
    let cellType: String
    let restatement: String?
    let originalPrompt: String?
    let blockName: String?
}
