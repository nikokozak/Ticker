import Foundation
import GRDB

/// An append kept verbatim until an editor can convert its provenance. See
/// migration v25.
struct PendingStreamAppend {
    let revision: Int
    let separator: String
    let fragment: String
    let rawSpansJSON: String
}

/// A Markdown fragment waiting for the JavaScript document reducer.
struct StreamAppendInboxEntry {
    let seq: Int
    let appendId: String
    let fragment: String
    let rawSpansJSON: String
    let createdAt: Date
}

struct AppendResult {
    let fragment: String
    let isNewDocument: Bool
    let revision: Int
    let spans: [ProvenanceSpan]
}

enum ExternalAppendResult {
    case legacy(AppendResult)
    case inbox([StreamAppendInboxEntry])
}

/// What an editor opens a stream with, read as one consistent state.
struct EditorSnapshot {
    let document: StreamDocument
    let spans: [ProvenanceSpan]
    let conversationAnchors: [ConversationAnchor]
    let pendingAppends: [PendingStreamAppend]
    let appendInbox: [StreamAppendInboxEntry]
}

struct StreamDocumentRevisionConflict: Error {
    let streamId: UUID
    let docJSON: String?
    let docFormatVersion: Int?
    let markdown: String
    let revision: Int
    let spans: [ProvenanceSpan]
    let conversationAnchors: [ConversationAnchor]
    let pendingAppends: [PendingStreamAppend]
    let appendInbox: [StreamAppendInboxEntry]
}

enum PersistenceError: LocalizedError {
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let message):
            return message
        }
    }
}

/// Manages SQLite persistence for streams, stream documents, and sources
final class PersistenceService {
    private let dbQueue: DatabaseQueue
    private let databaseURL: URL
    private let didDatabaseExistOnInit: Bool
    private let usesAppendInbox: Bool

    private static let databaseBackupRetentionCount = 5
    private static func debugLog(_ message: String) {
#if DEBUG
        print(message)
#endif
    }

    private static func wordCount(in markdown: String) -> Int {
        markdown.split { $0.isWhitespace }.count
    }

    /** Schema v1's only document Swift ever constructs: an empty new stream. */
    private static let emptyDocumentJSON =
        #"{"type":"doc","content":[{"type":"paragraph"}]}"#

    init(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default,
        usesAppendInbox: Bool = false
    ) throws {
        let databaseURL = databaseURL ?? Self.databaseURL(fileManager: fileManager)
        self.databaseURL = databaseURL
        self.didDatabaseExistOnInit = fileManager.fileExists(atPath: databaseURL.path)
        self.usesAppendInbox = usesAppendInbox

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrate()
        if usesAppendInbox {
            try requireCanonicalDocuments()
        }
    }

    private static func databaseURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let tickerDir = appSupport.appendingPathComponent("Ticker-Next", isDirectory: true)
        return tickerDir.appendingPathComponent("ticker.db")
    }

    /**
     * The cutover has no Markdown fallback. Starting one writer against even one
     * unconverted stream would make captures work selectively and hide the missing
     * document until that stream was opened.
     */
    private func requireCanonicalDocuments() throws {
        let unavailable = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM streams s
                    LEFT JOIN stream_documents d ON d.stream_id = s.id
                    WHERE d.stream_id IS NULL
                       OR d.doc_json IS NULL
                       OR d.doc_format_version != 1
                """
            ) ?? 0
        }
        guard unavailable == 0 else {
            throw PersistenceError.encodingFailed(
                "\(unavailable) stream document(s) still require canonical conversion"
            )
        }
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

        migrator.registerMigration("v10_stream_documents") { db in
            try db.create(table: "stream_documents") { t in
                t.column("stream_id", .text).primaryKey()
                    .references("streams", onDelete: .cascade)
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }
        }

        migrator.registerMigration("v11_recover_orphaned_quickpanel_cells") { db in
            let documentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT stream_id, markdown, created_at
                    FROM stream_documents
                """
            )

            for documentRow in documentRows {
                let streamId: String = documentRow["stream_id"]
                let documentMarkdown: String = documentRow["markdown"]
                let documentCreatedAt: Double = documentRow["created_at"]

                let cellRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT content
                        FROM cells
                        WHERE stream_id = ?
                          AND created_at > ?
                        ORDER BY created_at ASC, position ASC
                    """,
                    arguments: [streamId, documentCreatedAt]
                )

                let recoveredFragments: [String] = cellRows.compactMap { row in
                    let content: String = row["content"]
                    let markdown = Self.markdownishTextFromLegacyCellHTML(content)
                    return markdown.isEmpty ? nil : markdown
                }

                guard !recoveredFragments.isEmpty else { continue }

                let recoveryBlock = (["## Recovered captures"] + recoveredFragments)
                    .joined(separator: "\n\n")
                let recoveredMarkdown = documentMarkdown.isEmpty
                    ? recoveryBlock
                    : "\(documentMarkdown)\n\n\(recoveryBlock)"
                let now = Date().timeIntervalSince1970

                try db.execute(
                    sql: """
                        UPDATE stream_documents
                        SET markdown = ?, updated_at = ?
                        WHERE stream_id = ?
                    """,
                    arguments: [recoveredMarkdown, now, streamId]
                )
            }

            // ponytail: Retain legacy cells until Phase 2+ drops the cells table in a future migration.
        }

        migrator.registerMigration("v12_seed_documents_from_legacy_cells") { db in
            let streamRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id
                    FROM streams s
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM stream_documents d
                        WHERE d.stream_id = s.id
                    )
                    AND EXISTS (
                        SELECT 1
                        FROM cells c
                        WHERE c.stream_id = s.id
                    )
                """
            )

            for streamRow in streamRows {
                let streamId: String = streamRow["id"]
                let cellRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT content
                        FROM cells
                        WHERE stream_id = ?
                        ORDER BY position ASC, created_at ASC
                    """,
                    arguments: [streamId]
                )

                let fragments: [String] = cellRows.compactMap { row in
                    let content: String = row["content"]
                    let markdown = Self.markdownishTextFromLegacyCellHTML(content)
                    return markdown.isEmpty ? nil : markdown
                }
                let markdown = fragments.joined(separator: "\n\n")
                let now = Date().timeIntervalSince1970

                try db.execute(
                    sql: """
                        INSERT INTO stream_documents (stream_id, markdown, created_at, updated_at)
                        VALUES (?, ?, ?, ?)
                    """,
                    arguments: [streamId, markdown, now, now]
                )
            }
        }

        migrator.registerMigration("v13_stream_document_revision") { db in
            try db.alter(table: "stream_documents") { t in
                t.add(column: "revision", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v14_pdf_highlights") { db in
            try db.create(table: "pdf_highlights") { t in
                t.column("id", .text).primaryKey()
                t.column("source_id", .text).notNull()
                    .references("sources", onDelete: .cascade)
                t.column("page", .integer).notNull()
                t.column("rects_json", .text).notNull()
                t.column("quote", .text).notNull()
                t.column("created_at", .text).notNull()
            }
            try db.create(index: "idx_pdf_highlights_source", on: "pdf_highlights", columns: ["source_id"])
        }

        migrator.registerMigration("v15_source_original_path") { db in
            try db.alter(table: "sources") { t in
                t.add(column: "original_path", .text)
            }
        }

        migrator.registerMigration("v16_source_chunk_index") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS source_chunks_delete_fts")
            try db.execute(sql: "DROP TABLE IF EXISTS source_chunks_fts")
            try db.execute(sql: "DROP TABLE IF EXISTS chunk_embeddings")
            try db.execute(sql: "DROP TABLE IF EXISTS source_chunks")

            try db.create(table: "source_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("source_id", .text).notNull()
                    .references("sources", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("page_start", .integer).notNull()
                t.column("page_end", .integer).notNull()
                t.column("section_path", .text)
            }
            try db.create(index: "idx_source_chunks_source", on: "source_chunks", columns: ["source_id"])

            // Standalone FTS duplicates chunk text and keeps unindexed ids so delete-by-source is a single local operation.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE source_chunks_fts USING fts5(
                    chunk_id UNINDEXED,
                    source_id UNINDEXED,
                    text
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER source_chunks_delete_fts
                AFTER DELETE ON source_chunks
                BEGIN
                    DELETE FROM source_chunks_fts WHERE chunk_id = old.id;
                END
            """)

            try db.alter(table: "sources") { t in
                t.add(column: "index_status", .text).notNull().defaults(to: "pending")
            }
        }

        migrator.registerMigration("v17_source_ai_exclusion") { db in
            try db.alter(table: "sources") { t in
                t.add(column: "ai_excluded", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v18_living_auto_titles") { db in
            try db.execute(sql: "ALTER TABLE streams ADD COLUMN title_locked INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE streams ADD COLUMN auto_titled_at DOUBLE")
            try db.execute(sql: "ALTER TABLE streams ADD COLUMN auto_titled_length INTEGER")
            try db.execute(sql: "ALTER TABLE streams ADD COLUMN source_scope TEXT NOT NULL DEFAULT 'auto'")
            try db.execute(sql: """
                UPDATE streams
                SET title_locked = 1
                WHERE title IS NOT NULL
                  AND title != ''
                  AND title != 'Untitled'
            """)
        }

        migrator.registerMigration("v19_scroll_restore") { db in
            try db.execute(sql: "ALTER TABLE stream_documents ADD COLUMN scroll_offset REAL NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE sources ADD COLUMN last_page_index INTEGER")
        }

        migrator.registerMigration("v20_provenance_layer") { db in
            try db.execute(sql: """
                CREATE TABLE provenance_spans (
                  span_id     TEXT PRIMARY KEY,
                  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                  start       INTEGER NOT NULL,          -- UTF-16 code units into stream_documents.markdown
                  end         INTEGER NOT NULL,          -- exclusive
                  origin      TEXT NOT NULL,             -- 'ai' | 'source' | 'capture'
                  request_id  TEXT,                      -- ai origin: links to ai_exchanges
                  source_id   TEXT,                      -- source origin
                  meta        TEXT NOT NULL DEFAULT '{}',-- JSON: model, page, sourceApp, parent_request_id
                  text_hash   TEXT NOT NULL,             -- FNV-1a 32-bit hex of covered text (see below)
                  created_at  DOUBLE NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_prov_stream ON provenance_spans(stream_id);")
            try db.execute(sql: """
                CREATE TABLE ai_exchanges (
                  request_id  TEXT PRIMARY KEY,
                  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                  verb        TEXT NOT NULL,
                  user_input  TEXT NOT NULL,             -- selection + typed prompt, labeled, plain text
                  source_manifest TEXT NOT NULL DEFAULT '[]',  -- JSON array as built for citations
                  response_raw TEXT NOT NULL,            -- pre-citation-swap model output
                  model       TEXT,                      -- from documentModelSelected
                  created_at  DOUBLE NOT NULL
                );
                """)
        }

        migrator.registerMigration("v21_margin_notes") { db in
            try db.execute(sql: """
                CREATE TABLE margin_notes (
                  note_id     TEXT PRIMARY KEY,
                  stream_id   TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                  anchor_start INTEGER NOT NULL,         -- UTF-16, mapped like spans
                  anchor_end   INTEGER NOT NULL,
                  anchor_hash  TEXT NOT NULL,            -- FNV-1a of anchored text
                  kind        TEXT NOT NULL,             -- 'question' | 'tension' | 'connection'
                  body        TEXT NOT NULL,
                  body_hash   TEXT NOT NULL,             -- dedupe/suppression key
                  request_id  TEXT,
                  status      TEXT NOT NULL DEFAULT 'open',  -- open|dismissed|promoted|unanchored
                  created_at  DOUBLE NOT NULL
                );
                CREATE INDEX idx_margin_stream ON margin_notes(stream_id);
                CREATE TABLE margin_suppressions ( stream_id TEXT NOT NULL, body_hash TEXT NOT NULL,
                  PRIMARY KEY (stream_id, body_hash) );
                """)
        }

        migrator.registerMigration("v22_stream_document_word_count") { db in
            try db.alter(table: "stream_documents") { t in
                t.add(column: "word_count", .integer).notNull().defaults(to: 0)
            }

            let documents = try Row.fetchAll(db, sql: "SELECT stream_id, markdown FROM stream_documents")
            for document in documents {
                let markdown: String = document["markdown"]
                try db.execute(
                    sql: "UPDATE stream_documents SET word_count = ? WHERE stream_id = ?",
                    arguments: [Self.wordCount(in: markdown), document["stream_id"] as String]
                )
            }
        }

        migrator.registerMigration("v23_chunk_embeddings") { db in
            try db.create(table: "chunk_embeddings") { t in
                t.column("chunk_id", .text).primaryKey()
                    .references("source_chunks", onDelete: .cascade)
                t.column("model_id", .text).notNull()
                t.column("dims", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
        }

        /// Provenance coordinates changed meaning: `start`/`end` now hold
        /// ProseMirror document positions instead of offsets into the Markdown.
        /// They are the same integers measured against a different thing, so an old
        /// row is indistinguishable from a new one and cannot be converted without
        /// parsing every document. Clearing the table loses the AI-authorship
        /// highlighting on existing streams; it does not touch a word of anyone's
        /// writing, and the alternative is highlights that point at the wrong text.
        migrator.registerMigration("v24_provenance_document_positions") { db in
            try db.execute(sql: "DELETE FROM provenance_spans")
        }

        /// Provenance for an append made while no editor was open.
        ///
        /// The store cannot record it in `provenance_spans`: those coordinates are
        /// ProseMirror document positions, and knowing one means parsing the
        /// document, which is the editor's job. What the store CAN say exactly is
        /// "this fragment, with these offsets inside it" — so it keeps the append
        /// verbatim until an editor opens the stream, converts the offsets, and
        /// saves. The row is deleted only by a successful revision-checked save.
        migrator.registerMigration("v25_pending_stream_appends") { db in
            try db.execute(sql: """
                CREATE TABLE pending_stream_appends (
                    stream_id      TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                    revision       INTEGER NOT NULL CHECK (revision > 0),
                    separator      TEXT NOT NULL,
                    fragment       TEXT NOT NULL,
                    raw_spans_json TEXT NOT NULL DEFAULT '[]',
                    PRIMARY KEY (stream_id, revision)
                )
            """)
            // Any span written between v24 and here is still coordinate-ambiguous.
            try db.execute(sql: "DELETE FROM provenance_spans")
        }

        migrator.registerMigration("v26_canonical_stream_documents") { db in
            try db.execute(sql: """
                ALTER TABLE stream_documents ADD COLUMN doc_json TEXT;
                ALTER TABLE stream_documents ADD COLUMN doc_format_version INTEGER
                    CHECK ((doc_json IS NULL) = (doc_format_version IS NULL));

                CREATE TABLE stream_append_inbox (
                    seq            INTEGER PRIMARY KEY AUTOINCREMENT,
                    append_id      TEXT NOT NULL UNIQUE,
                    stream_id      TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                    fragment       TEXT NOT NULL,
                    raw_spans_json TEXT NOT NULL DEFAULT '[]',
                    created_at     REAL NOT NULL
                );
                CREATE INDEX idx_append_inbox_stream ON stream_append_inbox (stream_id, seq);
            """)
        }

        migrator.registerMigration("v27_append_inbox_receipts") { db in
            // A consumed identity must outlive its pending row or a delayed retry
            // inserts the same capture twice after the editor has already saved it.
            // ponytail: retain the small receipt verbatim; compact it to hashes only
            // if inbox history becomes measurable database growth.
            try db.execute(sql: """
                ALTER TABLE stream_append_inbox ADD COLUMN consumed_at REAL;
            """)
        }

        migrator.registerMigration("v28_stream_threads") { db in
            try db.execute(sql: """
                CREATE TABLE stream_threads (
                    thread_id      TEXT PRIMARY KEY,
                    stream_id      TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                    title          TEXT NOT NULL DEFAULT '',
                    working_text   TEXT NOT NULL DEFAULT '',
                    anchor_text    TEXT NOT NULL DEFAULT '',
                    anchor_span_id TEXT,
                    source_id      TEXT REFERENCES sources(id) ON DELETE SET NULL,
                    highlight_id   TEXT REFERENCES pdf_highlights(id) ON DELETE SET NULL,
                    revision       INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                    created_at     DOUBLE NOT NULL,
                    updated_at     DOUBLE NOT NULL
                );
                CREATE INDEX idx_stream_threads_stream_updated
                    ON stream_threads(stream_id, updated_at DESC);

                ALTER TABLE ai_exchanges ADD COLUMN thread_id TEXT
                    REFERENCES stream_threads(thread_id) ON DELETE SET NULL;
                CREATE INDEX idx_ai_exchanges_thread
                    ON ai_exchanges(thread_id, created_at);
            """)
        }

        migrator.registerMigration("v29_sidenote_documents") { db in
            try db.execute(sql: """
                ALTER TABLE stream_threads ADD COLUMN doc_json TEXT;
                ALTER TABLE stream_threads ADD COLUMN doc_format_version INTEGER
                    CHECK ((doc_json IS NULL) = (doc_format_version IS NULL));
                ALTER TABLE ai_exchanges ADD COLUMN thread_disposition TEXT
                    CHECK (thread_disposition IS NULL OR
                           thread_disposition IN ('pending', 'kept', 'discarded'));

                CREATE TABLE stream_thread_anchors (
                    anchor_id      TEXT PRIMARY KEY,
                    thread_id      TEXT NOT NULL REFERENCES stream_threads(thread_id)
                                   ON DELETE CASCADE,
                    kind           TEXT NOT NULL CHECK
                                   (kind IN ('stream_quote', 'pdf_quote', 'placement')),
                    quote          TEXT,
                    anchor_span_id TEXT,
                    source_id      TEXT REFERENCES sources(id) ON DELETE SET NULL,
                    highlight_id   TEXT REFERENCES pdf_highlights(id) ON DELETE SET NULL,
                    created_at     DOUBLE NOT NULL,
                    CHECK (
                        (kind = 'pdf_quote' AND quote IS NOT NULL
                         AND anchor_span_id IS NULL) OR
                        (kind = 'stream_quote' AND quote IS NOT NULL
                         AND source_id IS NULL AND highlight_id IS NULL) OR
                        (kind = 'placement' AND quote IS NULL AND anchor_span_id IS NOT NULL
                         AND source_id IS NULL AND highlight_id IS NULL)
                    )
                );
                CREATE INDEX idx_stream_thread_anchors_thread
                    ON stream_thread_anchors(thread_id, created_at);
                CREATE INDEX idx_stream_thread_anchors_span
                    ON stream_thread_anchors(anchor_span_id);

                INSERT INTO stream_thread_anchors
                    (anchor_id, thread_id, kind, quote, anchor_span_id,
                     source_id, highlight_id, created_at)
                SELECT thread_id || ':legacy', thread_id,
                       CASE WHEN source_id IS NOT NULL AND highlight_id IS NOT NULL
                            THEN 'pdf_quote' ELSE 'stream_quote' END,
                       anchor_text, anchor_span_id, source_id, highlight_id, created_at
                FROM stream_threads;
            """)
        }

        migrator.registerMigration("v30_conversation_anchors") { db in
            try db.execute(sql: """
                ALTER TABLE stream_threads ADD COLUMN anchor_start INTEGER;
                ALTER TABLE stream_threads ADD COLUMN anchor_end   INTEGER;
                ALTER TABLE stream_threads ADD COLUMN detached     INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE stream_threads ADD COLUMN ephemeral    INTEGER NOT NULL DEFAULT 0;
                UPDATE stream_threads SET detached = 1;
            """)
        }

        migrator.registerMigration("v31_conversation_profiles") { db in
            try db.execute(sql: """
                ALTER TABLE stream_threads ADD COLUMN profile TEXT
                    CHECK (profile IS NULL OR profile = 'research');
            """)
        }

        if didDatabaseExistOnInit {
            let hasPendingMigrations = try dbQueue.read { db in
                try !migrator.hasCompletedMigrations(db)
            }
            if hasPendingMigrations {
                try backupDatabaseBeforeMigration(retainingLast: Self.databaseBackupRetentionCount)
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

        do {
            try rotateBackups(in: backupsDirectory, retainingLast: retentionCount)
        } catch {
            Self.debugLog("PersistenceService: Failed to rotate old DB backups: \(error)")
        }
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

    private static let pdfHighlightDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Stream Operations

    func loadStreamSummaries() throws -> [StreamSummary] {
        try dbQueue.read { db in
            let sql = """
                SELECT
                    s.id, s.title, s.updated_at,
                    (SELECT COUNT(*) FROM sources WHERE stream_id = s.id) as source_count,
                    (SELECT display_name FROM sources WHERE stream_id = s.id ORDER BY added_at LIMIT 1) as source_display_name,
                    (SELECT COUNT(*) FROM margin_notes WHERE stream_id = s.id AND status = 'open' AND kind = 'question') as open_question_count,
                    LENGTH(d.markdown) as char_count,
                    d.word_count,
                    (LENGTH(d.markdown) - LENGTH(REPLACE(d.markdown, '![', ''))) / 2 as image_count,
                    SUBSTR(d.markdown, 1, 2000) as preview_prefix
                FROM streams s
                LEFT JOIN stream_documents d ON d.stream_id = s.id
                ORDER BY s.updated_at DESC
            """
            return try Row.fetchAll(db, sql: sql).map { row in
                let sourceCount: Int = row["source_count"]
                let sourceDisplayName: String? = row["source_display_name"]
                return StreamSummary(
                    id: UUID(uuidString: row["id"])!,
                    title: row["title"],
                    sourceCount: sourceCount,
                    sourceShortTitle: sourceCount == 1 ? sourceDisplayName.map { SourceShortTitle.derive(displayName: $0) } : nil,
                    charCount: row["char_count"] ?? 0,
                    wordCount: row["word_count"] ?? 0,
                    imageCount: row["image_count"] ?? 0,
                    openQuestionCount: row["open_question_count"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    previewPrefix: row["preview_prefix"]
                )
            }
        }
    }

    func getStreamTitle(id: UUID) throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT title FROM streams WHERE id = ?", arguments: [id.uuidString])?["title"]
        }
    }

    func resolveUniqueStreamTitle(_ title: String) throws -> StreamTitleResolution {
        try dbQueue.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM streams WHERE title = ? ORDER BY updated_at DESC LIMIT 2",
                arguments: [title]
            ).compactMap(UUID.init(uuidString:))

            switch ids.count {
            case 0: return .notFound
            case 1: return .unique(ids[0])
            default: return .ambiguous
            }
        }
    }

    func loadStream(id: UUID) throws -> Stream? {
        try dbQueue.read { db in
            guard let streamRow = try Row.fetchOne(db, sql: "SELECT * FROM streams WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }

            let sourceRows = try Row.fetchAll(db, sql: "SELECT * FROM sources WHERE stream_id = ? ORDER BY added_at", arguments: [id.uuidString])
            let sources = sourceRows.map { row -> SourceReference in
                let embeddingStatusRaw: String? = row["embedding_status"]
                let embeddingStatus = embeddingStatusRaw.flatMap { SourceEmbeddingStatus(rawValue: $0) } ?? .none
                let indexStatusRaw: String? = row["index_status"]
                let indexStatus = indexStatusRaw.flatMap { SourceIndexStatus(rawValue: $0) } ?? .pending
                let aiExcluded: Int = row["ai_excluded"]

                return SourceReference(
                    id: UUID(uuidString: row["id"])!,
                    streamId: UUID(uuidString: row["stream_id"])!,
                    displayName: row["display_name"],
                    fileType: SourceFileType(rawValue: row["file_type"]) ?? .text,
                    bookmarkData: row["bookmark_data"],
                    originalPath: row["original_path"],
                    status: SourceStatus(rawValue: row["status"]) ?? .pending,
                    extractedText: row["extracted_text"],
                    pageCount: row["page_count"],
                    embeddingStatus: embeddingStatus,
                    indexStatus: indexStatus,
                    aiExcluded: aiExcluded != 0,
                    lastPageIndex: row["last_page_index"],
                    addedAt: Date(timeIntervalSince1970: row["added_at"])
                )
            }

            return Stream(
                id: UUID(uuidString: streamRow["id"])!,
                title: streamRow["title"],
                sources: sources,
                sourceScope: SourceScope(rawValue: streamRow["source_scope"]) ?? .auto,
                createdAt: Date(timeIntervalSince1970: streamRow["created_at"]),
                updatedAt: Date(timeIntervalSince1970: streamRow["updated_at"])
            )
        }
    }

    func createStream(title: String) throws -> Stream {
        let stream = Stream(title: title)
        try saveStream(stream)
        return stream
    }

    func updateStream(_ stream: Stream) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE streams SET title = ?, source_scope = ?, updated_at = ? WHERE id = ?",
                arguments: [stream.title, stream.sourceScope.rawValue, Date().timeIntervalSince1970, stream.id.uuidString]
            )
        }
    }

    @discardableResult
    func setSourceScope(streamId: UUID, scope: SourceScope) throws -> Bool {
        try dbQueue.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM streams WHERE id = ?", arguments: [streamId.uuidString]) != nil else {
                return false
            }
            try db.execute(
                sql: "UPDATE streams SET source_scope = ? WHERE id = ?",
                arguments: [scope.rawValue, streamId.uuidString]
            )
            return true
        }
    }

    @discardableResult
    func updateStreamTitle(id: UUID, title: String) throws -> Bool {
        let now = Date().timeIntervalSince1970
        let locked = !(title.isEmpty || title == "Untitled")

        return try dbQueue.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM streams WHERE id = ?", arguments: [id.uuidString]) != nil else {
                return false
            }

            try db.execute(
                sql: """
                    UPDATE streams
                    SET title = ?, title_locked = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [title, locked ? 1 : 0, now, id.uuidString]
            )
            return true
        }
    }

    func loadAutoTitleState(streamId: UUID) throws -> AutoTitleState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, title, title_locked, auto_titled_at, auto_titled_length
                    FROM streams
                    WHERE id = ?
                """,
                arguments: [streamId.uuidString]
            ).map { row in
                let autoTitledAt: Double? = row["auto_titled_at"]
                let titleLocked: Int = row["title_locked"]
                return AutoTitleState(
                    streamId: UUID(uuidString: row["id"]) ?? streamId,
                    title: row["title"],
                    titleLocked: titleLocked != 0,
                    autoTitledAt: autoTitledAt.map(Date.init(timeIntervalSince1970:)),
                    autoTitledLength: row["auto_titled_length"]
                )
            }
        }
    }

    @discardableResult
    func applyAutoTitle(streamId: UUID, title: String, markdownLength: Int, now: Date = Date()) throws -> Bool {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT title_locked FROM streams WHERE id = ?",
                arguments: [streamId.uuidString]
            ) else {
                return false
            }
            let titleLocked: Int = row["title_locked"]
            guard titleLocked == 0 else { return false }

            try db.execute(
                sql: """
                    UPDATE streams
                    SET title = ?, auto_titled_at = ?, auto_titled_length = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    title,
                    now.timeIntervalSince1970,
                    markdownLength,
                    now.timeIntervalSince1970,
                    streamId.uuidString
                ]
            )
            return true
        }
    }

    func deleteStream(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM margin_suppressions WHERE stream_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM streams WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Save a new stream
    func saveStream(_ stream: Stream) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO streams (id, title, source_scope, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                stream.id.uuidString,
                stream.title,
                stream.sourceScope.rawValue,
                stream.createdAt.timeIntervalSince1970,
                stream.updatedAt.timeIntervalSince1970
            ])
            if usesAppendInbox {
                // A quick-panel capture can be the stream's first write. Seeding the
                // one fixed empty document here keeps Swift from parsing Markdown
                // while still giving that capture a canonical base to queue against.
                try db.execute(
                    sql: """
                        INSERT INTO stream_documents
                            (stream_id, doc_json, doc_format_version, markdown, word_count, revision, created_at, updated_at)
                        VALUES (?, ?, 1, '', 0, 0, ?, ?)
                    """,
                    arguments: [
                        stream.id.uuidString,
                        Self.emptyDocumentJSON,
                        stream.createdAt.timeIntervalSince1970,
                        stream.updatedAt.timeIntervalSince1970
                    ]
                )
            }
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

    // MARK: - Stream Document Operations

    func loadStreamDocument(streamId: UUID) throws -> StreamDocument? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT stream_id, doc_json, doc_format_version, markdown, revision, scroll_offset, created_at, updated_at FROM stream_documents WHERE stream_id = ?",
                arguments: [streamId.uuidString]
            ) else {
                return nil
            }

            return StreamDocument(
                streamId: UUID(uuidString: row["stream_id"]) ?? streamId,
                docJSON: row["doc_json"],
                docFormatVersion: row["doc_format_version"],
                markdown: row["markdown"],
                revision: row["revision"],
                scrollOffset: row["scroll_offset"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    @discardableResult
    func loadOrCreateStreamDocument(streamId: UUID) throws -> StreamDocument {
        try dbQueue.write { db in
            try loadOrCreateStreamDocument(streamId: streamId, db: db)
        }
    }

    /// Everything an editor needs to open a stream, read in ONE transaction.
    ///
    /// Separate reads let an append land between them, so the editor sees a
    /// document and inbox that never coexisted. It can only refuse that state:
    /// consuming a row it did not reduce loses a capture; saving without a row it
    /// did reduce duplicates it on the next open.
    func loadEditorSnapshot(streamId: UUID) throws -> EditorSnapshot {
        // A write, not a read, because the document may have to be created.
        try dbQueue.write { db in
            EditorSnapshot(
                document: try loadOrCreateStreamDocument(streamId: streamId, db: db),
                spans: try fetchSpans(streamId: streamId, db: db),
                conversationAnchors: try fetchConversationAnchors(streamId: streamId, db: db),
                pendingAppends: try fetchPendingAppends(streamId: streamId, db: db),
                appendInbox: try fetchAppendInbox(streamId: streamId, db: db)
            )
        }
    }

    private func loadOrCreateStreamDocument(streamId: UUID, db: Database) throws -> StreamDocument {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT stream_id, doc_json, doc_format_version, markdown, revision, scroll_offset, created_at, updated_at FROM stream_documents WHERE stream_id = ?",
            arguments: [streamId.uuidString]
        ) {
            return StreamDocument(
                streamId: UUID(uuidString: row["stream_id"]) ?? streamId,
                docJSON: row["doc_json"],
                docFormatVersion: row["doc_format_version"],
                markdown: row["markdown"],
                revision: row["revision"],
                scrollOffset: row["scroll_offset"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }

        // v12 seeds stream_documents for any legacy stream that still has cells,
        // so reaching this path means the stream is genuinely document-empty.
        let markdown = ""
        let now = Date()
        let nowTs = now.timeIntervalSince1970

        try db.execute(
            sql: """
                INSERT INTO stream_documents (stream_id, markdown, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [streamId.uuidString, markdown, nowTs, nowTs]
        )

        return StreamDocument(
            streamId: streamId,
            markdown: markdown,
            revision: 0,
            scrollOffset: 0,
            createdAt: now,
            updatedAt: now
        )
    }

    func saveScrollOffset(streamId: UUID, offset: Double) throws {
        let clampedOffset = max(0, offset)
        try dbQueue.write { db in
            guard try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM stream_documents WHERE stream_id = ?",
                arguments: [streamId.uuidString]
            ) != nil else {
                return
            }

            try db.execute(
                sql: "UPDATE stream_documents SET scroll_offset = ? WHERE stream_id = ?",
                arguments: [clampedOffset, streamId.uuidString]
            )
        }
    }

    @discardableResult
    func saveStreamDocument(streamId: UUID, markdown: String) throws -> Int {
        let document = try loadOrCreateStreamDocument(streamId: streamId)
        return try saveStreamDocument(streamId: streamId, markdown: markdown, baseRevision: document.revision)
    }

    @discardableResult
    func saveStreamDocument(streamId: UUID, markdown: String, baseRevision: Int) throws -> Int {
        try saveStreamDocument(streamId: streamId, markdown: markdown, baseRevision: baseRevision, spans: nil)
    }

    @discardableResult
    /// `resolvedPendingThrough` is the highest append revision whose provenance the
    /// editor has converted into the spans it is sending. Only those rows are
    /// forgotten; an editor that does not understand pending appends omits it and
    /// leaves every row in place.
    func saveStreamDocument(
        streamId: UUID,
        markdown: String,
        baseRevision: Int,
        spans: [ProvenanceSpan],
        resolvedPendingThrough: Int? = nil
    ) throws -> Int {
        try saveStreamDocument(
            streamId: streamId,
            markdown: markdown,
            baseRevision: baseRevision,
            spans: Optional(spans),
            resolvedPendingThrough: resolvedPendingThrough
        )
    }

    @discardableResult
    func saveStreamDocument(
        streamId: UUID,
        docJSON: String,
        docFormatVersion: Int,
        markdown: String,
        baseRevision: Int,
        spans: [ProvenanceSpan],
        conversationAnchors: [ConversationAnchorUpdate] = [],
        resolvedPendingThrough: Int? = nil,
        consumedInboxThrough: Int? = nil
    ) throws -> Int {
        guard docFormatVersion == 1,
              let data = docJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw PersistenceError.encodingFailed("Invalid canonical stream document")
        }
        return try saveStreamDocument(
            streamId: streamId,
            markdown: markdown,
            baseRevision: baseRevision,
            spans: Optional(spans),
            conversationAnchors: conversationAnchors,
            resolvedPendingThrough: resolvedPendingThrough,
            consumedInboxThrough: consumedInboxThrough,
            canonicalDocument: (docJSON, docFormatVersion)
        )
    }

    // ponytail: nil/partial anchor updates preserve omitted rows; delete this legacy-save landmine with StreamEditor.
    @discardableResult
    private func saveStreamDocument(
        streamId: UUID,
        markdown: String,
        baseRevision: Int,
        spans: [ProvenanceSpan]?,
        conversationAnchors: [ConversationAnchorUpdate]? = nil,
        resolvedPendingThrough: Int? = nil,
        consumedInboxThrough: Int? = nil,
        canonicalDocument: (json: String, version: Int)? = nil
    ) throws -> Int {
        let now = Date().timeIntervalSince1970
        return try dbQueue.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT doc_json, doc_format_version, markdown, revision FROM stream_documents WHERE stream_id = ?",
                arguments: [streamId.uuidString]
            ) {
                let currentDocJSON: String? = row["doc_json"]
                let currentDocFormatVersion: Int? = row["doc_format_version"]
                let currentMarkdown: String = row["markdown"]
                let currentRevision: Int = row["revision"]

                guard baseRevision == currentRevision else {
                    throw StreamDocumentRevisionConflict(
                        streamId: streamId,
                        docJSON: currentDocJSON,
                        docFormatVersion: currentDocFormatVersion,
                        markdown: currentMarkdown,
                        revision: currentRevision,
                        spans: try fetchSpans(streamId: streamId, db: db),
                        conversationAnchors: try fetchConversationAnchors(streamId: streamId, db: db),
                        pendingAppends: try fetchPendingAppends(streamId: streamId, db: db),
                        appendInbox: try fetchAppendInbox(streamId: streamId, db: db)
                    )
                }

                if canonicalDocument != nil {
                    try clearConsumedAppendInbox(
                        streamId: streamId,
                        through: consumedInboxThrough,
                        db: db
                    )
                }
                let storedMarkdown = canonicalDocument == nil
                    ? markdown
                    : try markdownProjectionIncludingInbox(markdown, streamId: streamId, db: db)
                let newRevision = currentRevision + 1
                if let canonicalDocument {
                    try db.execute(
                        sql: """
                            UPDATE stream_documents
                            SET doc_json = ?, doc_format_version = ?,
                                markdown = ?, word_count = ?, revision = ?, updated_at = ?
                            WHERE stream_id = ?
                        """,
                        arguments: [
                            canonicalDocument.json,
                            canonicalDocument.version,
                            storedMarkdown,
                            Self.wordCount(in: storedMarkdown),
                            newRevision,
                            now,
                            streamId.uuidString
                        ]
                    )
                } else {
                    // A legacy writer changed the projection, so the previous JSON
                    // no longer describes this revision and must not look usable.
                    try db.execute(
                        sql: """
                            UPDATE stream_documents
                            SET doc_json = NULL, doc_format_version = NULL,
                                markdown = ?, word_count = ?, revision = ?, updated_at = ?
                            WHERE stream_id = ?
                        """,
                        arguments: [markdown, Self.wordCount(in: markdown), newRevision, now, streamId.uuidString]
                    )
                }

                try db.execute(
                    sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                    arguments: [now, streamId.uuidString]
                )

                if let spans {
                    let validSpans = validatedSpans(spans, streamId: streamId)
                    logDroppedSpans(total: spans.count, kept: validSpans.count, context: "saveStreamDocument")
                    try replaceSpans(streamId: streamId, spans: validSpans, db: db)
                    try clearResolvedPendingAppends(
                        streamId: streamId,
                        through: resolvedPendingThrough,
                        baseRevision: baseRevision,
                        db: db
                    )
                    try deleteOrphanExchanges(streamId: streamId, db: db)
                }
                if let conversationAnchors {
                    try updateConversationAnchors(
                        streamId: streamId,
                        anchors: conversationAnchors,
                        db: db
                    )
                }

                return newRevision
            }

            guard baseRevision == 0 else {
                throw StreamDocumentRevisionConflict(
                    streamId: streamId,
                    docJSON: nil,
                    docFormatVersion: nil,
                    markdown: "",
                    revision: 0,
                    spans: [],
                    conversationAnchors: [],
                    pendingAppends: try fetchPendingAppends(streamId: streamId, db: db),
                    appendInbox: try fetchAppendInbox(streamId: streamId, db: db)
                )
            }

            if canonicalDocument != nil {
                try clearConsumedAppendInbox(
                    streamId: streamId,
                    through: consumedInboxThrough,
                    db: db
                )
            }
            let storedMarkdown = canonicalDocument == nil
                ? markdown
                : try markdownProjectionIncludingInbox(markdown, streamId: streamId, db: db)
            let newRevision = 1
            if let canonicalDocument {
                try db.execute(
                    sql: """
                        INSERT INTO stream_documents
                            (stream_id, doc_json, doc_format_version, markdown, word_count, revision, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        streamId.uuidString,
                        canonicalDocument.json,
                        canonicalDocument.version,
                        storedMarkdown,
                        Self.wordCount(in: storedMarkdown),
                        newRevision,
                        now,
                        now
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO stream_documents (stream_id, markdown, word_count, revision, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [streamId.uuidString, markdown, Self.wordCount(in: markdown), newRevision, now, now]
                )
            }

            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [now, streamId.uuidString]
            )

            if let spans {
                let validSpans = validatedSpans(spans, streamId: streamId)
                logDroppedSpans(total: spans.count, kept: validSpans.count, context: "saveStreamDocument")
                try replaceSpans(streamId: streamId, spans: validSpans, db: db)
                try clearResolvedPendingAppends(
                    streamId: streamId,
                    through: resolvedPendingThrough,
                    baseRevision: baseRevision,
                    db: db
                )
                try deleteOrphanExchanges(streamId: streamId, db: db)
            }
            if let conversationAnchors {
                try updateConversationAnchors(
                    streamId: streamId,
                    anchors: conversationAnchors,
                    db: db
                )
            }

            return newRevision
        }
    }

    func appendToStreamDocument(
        streamId: UUID,
        fragment: String,
        spans: [ProvenanceSpan] = [],
        exchange: AIExchange? = nil
    ) throws -> AppendResult {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            let existingMarkdown: String
            let existingRevision: Int
            let isNewDocument: Bool

            if let row = try Row.fetchOne(
                db,
                sql: "SELECT markdown, revision FROM stream_documents WHERE stream_id = ?",
                arguments: [streamId.uuidString]
            ) {
                existingMarkdown = row["markdown"]
                existingRevision = row["revision"]
                isNewDocument = false
            } else {
                existingMarkdown = ""
                existingRevision = 0
                isNewDocument = true
            }

            let separator = existingMarkdown.isEmpty ? "" : "\n\n"
            let markdown = existingMarkdown.isEmpty
                ? fragment
                : "\(existingMarkdown)\(separator)\(fragment)"
            let newRevision = existingRevision + 1
            /*
             * The spans stay exactly as they arrived: offsets into THIS fragment.
             * Shifting them by the length of the existing Markdown, which is what
             * used to happen here, produces an offset into the Markdown — and
             * provenance coordinates are ProseMirror document positions now, so
             * that number means nothing and points at the wrong text. Only an
             * editor can convert them, because only an editor has the document.
             */

            try db.execute(
                sql: """
                    INSERT INTO stream_documents (stream_id, markdown, word_count, revision, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(stream_id) DO UPDATE SET
                        doc_json = NULL,
                        doc_format_version = NULL,
                        markdown = excluded.markdown,
                        word_count = excluded.word_count,
                        revision = excluded.revision,
                        updated_at = excluded.updated_at
                """,
                arguments: [streamId.uuidString, markdown, Self.wordCount(in: markdown), newRevision, now, now]
            )

            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [now, streamId.uuidString]
            )

            // Recorded for EVERY append, including one with no spans: replaying
            // them on load means peeling the fragments off the end of the stored
            // Markdown in order, and a missing row breaks the sequence.
            try db.execute(
                sql: """
                    INSERT INTO pending_stream_appends (stream_id, revision, separator, fragment, raw_spans_json)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(stream_id, revision) DO UPDATE SET
                        separator = excluded.separator,
                        fragment = excluded.fragment,
                        raw_spans_json = excluded.raw_spans_json
                """,
                arguments: [streamId.uuidString, newRevision, separator, fragment, Self.encodeRawSpans(spans)]
            )

            if let exchange {
                try saveExchange(exchange, db: db)
            }

            return AppendResult(fragment: fragment, isNewDocument: isNewDocument, revision: newRevision, spans: spans)
        }
    }

    /**
     * The one deployment gate for every external producer. Switching callers
     * individually makes captures disappear depending on where they came from;
     * the composition root opts the whole app into the inbox at once.
     */
    func appendExternal(
        appendId: String,
        streamId: UUID,
        fragment: String,
        spans: [ProvenanceSpan] = [],
        exchange: AIExchange? = nil
    ) throws -> ExternalAppendResult {
        if usesAppendInbox {
            return .inbox(try enqueueStreamAppend(
                appendId: appendId,
                streamId: streamId,
                fragment: fragment,
                spans: spans,
                exchange: exchange
            ))
        }
        return .legacy(try appendToStreamDocument(
            streamId: streamId,
            fragment: fragment,
            spans: spans,
            exchange: exchange
        ))
    }

    /**
     * Store a Markdown command for JavaScript and update only the derived projection.
     *
     * Returning the FULL outstanding snapshot from this same transaction is the
     * ordering proof the live reducer needs. A single row can arrive out of order;
     * consuming its global sequence would then delete an earlier row from this
     * stream that the editor never saw.
     */
    func enqueueStreamAppend(
        appendId: String,
        streamId: UUID,
        fragment: String,
        spans: [ProvenanceSpan] = [],
        exchange: AIExchange? = nil
    ) throws -> [StreamAppendInboxEntry] {
        let trimmedId = appendId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty,
              !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.encodingFailed("Invalid stream append")
        }
        let rawSpansJSON = Self.encodeRawSpans(spans)

        return try dbQueue.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT stream_id, fragment, raw_spans_json
                    FROM stream_append_inbox
                    WHERE append_id = ?
                """,
                arguments: [trimmedId]
            ) {
                let same = existing["stream_id"] as String == streamId.uuidString
                    && existing["fragment"] as String == fragment
                    && existing["raw_spans_json"] as String == rawSpansJSON
                guard same else {
                    throw PersistenceError.encodingFailed("Append id was reused with different content")
                }
                return try fetchAppendInbox(streamId: streamId, db: db)
            }

            guard let document = try Row.fetchOne(
                db,
                sql: """
                    SELECT doc_json, doc_format_version, markdown
                    FROM stream_documents
                    WHERE stream_id = ?
                """,
                arguments: [streamId.uuidString]
            ) else {
                throw PersistenceError.encodingFailed("Canonical stream document is unavailable")
            }
            let docJSON: String? = document["doc_json"]
            let docFormatVersion: Int? = document["doc_format_version"]
            guard docJSON != nil, docFormatVersion == 1 else {
                throw PersistenceError.encodingFailed("Canonical stream document is unavailable")
            }

            let now = Date().timeIntervalSince1970
            let markdown: String = document["markdown"]
            let projection = markdown.isEmpty ? fragment : "\(markdown)\n\n\(fragment)"
            try db.execute(
                sql: """
                    UPDATE stream_documents
                    SET markdown = ?, word_count = ?, updated_at = ?
                    WHERE stream_id = ?
                """,
                arguments: [projection, Self.wordCount(in: projection), now, streamId.uuidString]
            )
            try db.execute(
                sql: "UPDATE streams SET updated_at = ? WHERE id = ?",
                arguments: [now, streamId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO stream_append_inbox
                        (append_id, stream_id, fragment, raw_spans_json, created_at)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [trimmedId, streamId.uuidString, fragment, rawSpansJSON, now]
            )
            if let exchange {
                try saveExchange(exchange, db: db)
            }
            return try fetchAppendInbox(streamId: streamId, db: db)
        }
    }

    // MARK: - Thread Operations

    @discardableResult
    func createStreamThread(
        _ thread: StreamThread,
        anchors: [StreamThreadAnchor] = [],
        pdfHighlights: [PDFHighlightRecord] = []
    ) throws -> StreamThread {
        try Self.validateThreadDocument(thread.docJSON, version: thread.docFormatVersion)
        return try dbQueue.write { db in
            guard try Row.fetchOne(
                db,
                sql: "SELECT id FROM streams WHERE id = ?",
                arguments: [thread.streamId.uuidString]
            ) != nil else {
                throw StreamThreadPersistenceError.streamNotFound
            }
            for highlight in pdfHighlights {
                try savePDFHighlight(highlight, db: db)
            }
            try validateThreadReferences(thread, db: db)
            for anchor in anchors {
                try validateThreadAnchor(anchor, thread: thread, db: db)
            }

            try db.execute(
                sql: """
                    INSERT INTO stream_threads
                        (thread_id, stream_id, title, working_text, doc_json, doc_format_version,
                         anchor_text, anchor_span_id, source_id, highlight_id,
                         anchor_start, anchor_end, detached, ephemeral, profile,
                         revision, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    thread.threadId.uuidString,
                    thread.streamId.uuidString,
                    thread.title,
                    thread.workingText,
                    thread.docJSON,
                    thread.docFormatVersion,
                    thread.anchorText,
                    thread.anchorSpanId,
                    thread.sourceId?.uuidString,
                    thread.highlightId?.uuidString,
                    thread.anchorStart,
                    thread.anchorEnd,
                    thread.detached,
                    thread.ephemeral,
                    thread.profile,
                    thread.revision,
                    thread.createdAt.timeIntervalSince1970,
                    thread.updatedAt.timeIntervalSince1970
                ]
            )
            for anchor in anchors {
                try insertThreadAnchor(anchor, db: db)
            }
            try db.execute(
                // Thread work is Stream activity, so it may move the Stream up in
                // the list, but a restored/imported timestamp must never move it back.
                sql: "UPDATE streams SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                arguments: [thread.updatedAt.timeIntervalSince1970, thread.streamId.uuidString]
            )
            return thread
        }
    }

    func loadStreamThreads(streamId: UUID) throws -> [StreamThread] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT thread_id, stream_id, title, working_text, anchor_text, anchor_span_id,
                           source_id, highlight_id, revision, created_at, updated_at,
                           doc_json, doc_format_version, anchor_start, anchor_end, detached, ephemeral,
                           profile
                    FROM stream_threads
                    WHERE stream_id = ?
                    ORDER BY updated_at DESC, thread_id
                """,
                arguments: [streamId.uuidString]
            ).compactMap(Self.decodeStreamThread)
        }
    }

    func loadStreamThread(threadId: UUID, streamId: UUID) throws -> StreamThread? {
        try dbQueue.read { db in
            try fetchStreamThread(threadId: threadId, streamId: streamId, db: db)
        }
    }

    func loadConversationAnchors(streamId: UUID) throws -> [ConversationAnchor] {
        try dbQueue.read { db in
            try fetchConversationAnchors(streamId: streamId, db: db)
        }
    }

    @discardableResult
    func saveStreamThread(
        threadId: UUID,
        streamId: UUID,
        title: String,
        baseRevision: Int,
        ephemeral: Bool? = nil
    ) throws -> StreamThread {
        return try dbQueue.write { db in
            let updatedAt = Date()
            try db.execute(
                sql: """
                    UPDATE stream_threads
                    SET title = ?, ephemeral = COALESCE(?, ephemeral),
                        revision = revision + 1, updated_at = ?
                    WHERE thread_id = ? AND stream_id = ? AND revision = ?
                """,
                arguments: [
                    title,
                    ephemeral,
                    updatedAt.timeIntervalSince1970,
                    threadId.uuidString,
                    streamId.uuidString,
                    baseRevision
                ]
            )

            guard db.changesCount == 1 else {
                guard let current = try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) else {
                    throw StreamThreadPersistenceError.threadNotFound
                }
                throw StreamThreadRevisionConflict(current: current)
            }

            try db.execute(
                sql: "UPDATE streams SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                arguments: [updatedAt.timeIntervalSince1970, streamId.uuidString]
            )
            guard let saved = try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            return saved
        }
    }

    func loadThreadExchanges(threadId: UUID, streamId: UUID) throws -> [AIExchange] {
        try dbQueue.read { db in
            guard try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) != nil else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT request_id, stream_id, thread_id, verb, user_input,
                           source_manifest, response_raw, model, thread_disposition, created_at
                    FROM ai_exchanges
                    WHERE thread_id = ? AND stream_id = ?
                    ORDER BY created_at, request_id
                """,
                arguments: [threadId.uuidString, streamId.uuidString]
            ).compactMap(Self.decodeExchange)
        }
    }

    func loadStreamThreadAnchors(threadId: UUID, streamId: UUID) throws -> [StreamThreadAnchor] {
        try dbQueue.read { db in
            guard try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) != nil else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            return try fetchThreadAnchors(threadId: threadId, db: db)
        }
    }

    @discardableResult
    func addStreamThreadAnchor(
        _ anchor: StreamThreadAnchor,
        streamId: UUID,
        pdfHighlight: PDFHighlightRecord? = nil
    ) throws -> StreamThreadAnchor {
        try dbQueue.write { db in
            guard let thread = try fetchStreamThread(
                threadId: anchor.threadId,
                streamId: streamId,
                db: db
            ) else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            if let pdfHighlight {
                try savePDFHighlight(pdfHighlight, db: db)
            }
            try validateThreadAnchor(anchor, thread: thread, db: db)
            try insertThreadAnchor(anchor, db: db)
            let updatedAt = anchor.createdAt.timeIntervalSince1970
            try db.execute(
                sql: "UPDATE stream_threads SET updated_at = MAX(updated_at, ?) WHERE thread_id = ?",
                arguments: [updatedAt, anchor.threadId.uuidString]
            )
            try db.execute(
                sql: "UPDATE streams SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                arguments: [updatedAt, streamId.uuidString]
            )
            return anchor
        }
    }

    @discardableResult
    func removeStreamThreadAnchor(
        anchorId: String,
        threadId: UUID,
        streamId: UUID
    ) throws -> Bool {
        try dbQueue.write { db in
            guard try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) != nil else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            let highlightId = try String.fetchOne(
                db,
                sql: "SELECT highlight_id FROM stream_thread_anchors WHERE anchor_id = ? AND thread_id = ?",
                arguments: [anchorId, threadId.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM stream_thread_anchors WHERE anchor_id = ? AND thread_id = ?",
                arguments: [anchorId, threadId.uuidString]
            )
            let removed = db.changesCount > 0
            if let highlightId, let id = UUID(uuidString: highlightId) {
                try deleteUnreferencedThreadHighlight(id, db: db)
            }
            return removed
        }
    }

    func deleteStreamThread(threadId: UUID, streamId: UUID) throws -> [UUID] {
        try dbQueue.write { db in
            guard try fetchStreamThread(threadId: threadId, streamId: streamId, db: db) != nil else {
                throw StreamThreadPersistenceError.threadNotFound
            }
            return try deleteStreamThreadRows(threadId: threadId, streamId: streamId, db: db)
        }
    }

    func deleteEphemeralThread(threadId: UUID, streamId: UUID) throws -> [UUID] {
        try dbQueue.write { db in
            let ephemeral = try Bool.fetchOne(
                db,
                sql: "SELECT ephemeral FROM stream_threads WHERE thread_id = ? AND stream_id = ?",
                arguments: [threadId.uuidString, streamId.uuidString]
            )
            guard ephemeral == true else {
                DebugLog.log("[Persistence] Skipped automatic deletion of kept conversation \(threadId)")
                return []
            }
            return try deleteStreamThreadRows(threadId: threadId, streamId: streamId, db: db)
        }
    }

    @discardableResult
    func deleteEphemeralThreads(streamId: UUID) throws -> Int {
        try dbQueue.write { db in
            let threadIds = try String.fetchAll(
                db,
                sql: "SELECT thread_id FROM stream_threads WHERE stream_id = ? AND ephemeral = 1",
                arguments: [streamId.uuidString]
            ).compactMap(UUID.init(uuidString:))
            for threadId in threadIds {
                _ = try deleteStreamThreadRows(threadId: threadId, streamId: streamId, db: db)
            }
            return threadIds.count
        }
    }

    private func deleteStreamThreadRows(
        threadId: UUID,
        streamId: UUID,
        db: Database
    ) throws -> [UUID] {
        let highlightIds = try String.fetchAll(
            db,
            sql: """
                SELECT highlight_id FROM stream_thread_anchors
                WHERE thread_id = ? AND highlight_id IS NOT NULL
            """,
            arguments: [threadId.uuidString]
        ).compactMap(UUID.init(uuidString:))
        try db.execute(
            sql: "DELETE FROM ai_exchanges WHERE thread_id = ? AND stream_id = ?",
            arguments: [threadId.uuidString, streamId.uuidString]
        )
        try db.execute(
            sql: "DELETE FROM stream_threads WHERE thread_id = ? AND stream_id = ?",
            arguments: [threadId.uuidString, streamId.uuidString]
        )
        for highlightId in highlightIds {
            try deleteUnreferencedThreadHighlight(highlightId, db: db)
        }
        return highlightIds
    }

    func setThreadExchangeDisposition(
        requestId: String,
        threadId: UUID,
        streamId: UUID,
        disposition: String
    ) throws {
        guard ["pending", "kept", "discarded"].contains(disposition) else {
            throw StreamThreadPersistenceError.invalidDisposition
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE ai_exchanges SET thread_disposition = ?
                    WHERE request_id = ? AND thread_id = ? AND stream_id = ?
                """,
                arguments: [disposition, requestId, threadId.uuidString, streamId.uuidString]
            )
            guard db.changesCount == 1 else {
                throw StreamThreadPersistenceError.exchangeOutsideThread
            }
        }
    }

    private func validateThreadReferences(_ thread: StreamThread, db: Database) throws {
        if let sourceId = thread.sourceId {
            let sourceStreamId = try String.fetchOne(
                db,
                sql: "SELECT stream_id FROM sources WHERE id = ?",
                arguments: [sourceId.uuidString]
            )
            guard sourceStreamId == thread.streamId.uuidString else {
                throw StreamThreadPersistenceError.sourceOutsideStream
            }
        }

        if let highlightId = thread.highlightId {
            guard let sourceId = thread.sourceId else {
                throw StreamThreadPersistenceError.highlightOutsideSource
            }
            let highlightSourceId = try String.fetchOne(
                db,
                sql: "SELECT source_id FROM pdf_highlights WHERE id = ?",
                arguments: [highlightId.uuidString]
            )
            guard highlightSourceId == sourceId.uuidString else {
                throw StreamThreadPersistenceError.highlightOutsideSource
            }
        }
    }

    private static func validateThreadDocument(_ docJSON: String?, version: Int?) throws {
        guard docJSON != nil || version != nil else { return }
        guard version == 1,
              let data = docJSON?.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw PersistenceError.encodingFailed("Invalid legacy thread document")
        }
    }

    private func deleteUnreferencedThreadHighlight(_ highlightId: UUID, db: Database) throws {
        let referenced = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM stream_thread_anchors WHERE highlight_id = ?
                    UNION ALL
                    SELECT 1 FROM stream_threads WHERE highlight_id = ?
                )
            """,
            arguments: [highlightId.uuidString, highlightId.uuidString]
        ) ?? false
        if !referenced {
            try db.execute(sql: "DELETE FROM pdf_highlights WHERE id = ?", arguments: [highlightId.uuidString])
        }
    }

    private func validateThreadAnchor(
        _ anchor: StreamThreadAnchor,
        thread: StreamThread,
        db: Database
    ) throws {
        guard anchor.threadId == thread.threadId else {
            throw StreamThreadPersistenceError.anchorOutsideThread
        }
        switch anchor.kind {
        case .streamQuote:
            guard anchor.quote != nil, anchor.sourceId == nil, anchor.highlightId == nil else {
                throw StreamThreadPersistenceError.invalidAnchor
            }
        case .pdfQuote:
            guard let sourceId = anchor.sourceId,
                  let highlightId = anchor.highlightId,
                  anchor.quote != nil,
                  anchor.anchorSpanId == nil else {
                throw StreamThreadPersistenceError.invalidAnchor
            }
            let sourceStreamId = try String.fetchOne(
                db,
                sql: "SELECT stream_id FROM sources WHERE id = ?",
                arguments: [sourceId.uuidString]
            )
            guard sourceStreamId == thread.streamId.uuidString else {
                throw StreamThreadPersistenceError.sourceOutsideStream
            }
            let highlightSourceId = try String.fetchOne(
                db,
                sql: "SELECT source_id FROM pdf_highlights WHERE id = ?",
                arguments: [highlightId.uuidString]
            )
            guard highlightSourceId == sourceId.uuidString else {
                throw StreamThreadPersistenceError.highlightOutsideSource
            }
        }
    }

    private func insertThreadAnchor(_ anchor: StreamThreadAnchor, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO stream_thread_anchors
                    (anchor_id, thread_id, kind, quote, anchor_span_id,
                     source_id, highlight_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                anchor.anchorId,
                anchor.threadId.uuidString,
                anchor.kind.rawValue,
                anchor.quote,
                anchor.anchorSpanId,
                anchor.sourceId?.uuidString,
                anchor.highlightId?.uuidString,
                anchor.createdAt.timeIntervalSince1970
            ]
        )
    }

    private func fetchThreadAnchors(threadId: UUID, db: Database) throws -> [StreamThreadAnchor] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT anchor_id, thread_id, kind, quote, anchor_span_id,
                       source_id, highlight_id, created_at
                FROM stream_thread_anchors
                WHERE thread_id = ?
                ORDER BY created_at, anchor_id
            """,
            arguments: [threadId.uuidString]
        ).compactMap { row in
            guard let threadId = UUID(uuidString: row["thread_id"]),
                  let kind = StreamThreadAnchorKind(rawValue: row["kind"]) else {
                return nil
            }
            let sourceIdRaw: String? = row["source_id"]
            let highlightIdRaw: String? = row["highlight_id"]
            return StreamThreadAnchor(
                anchorId: row["anchor_id"],
                threadId: threadId,
                kind: kind,
                quote: row["quote"],
                anchorSpanId: row["anchor_span_id"],
                sourceId: sourceIdRaw.flatMap(UUID.init(uuidString:)),
                highlightId: highlightIdRaw.flatMap(UUID.init(uuidString:)),
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    private func fetchStreamThread(threadId: UUID, streamId: UUID, db: Database) throws -> StreamThread? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT thread_id, stream_id, title, working_text, anchor_text, anchor_span_id,
                       source_id, highlight_id, revision, created_at, updated_at,
                       doc_json, doc_format_version, anchor_start, anchor_end, detached, ephemeral,
                       profile
                FROM stream_threads
                WHERE thread_id = ? AND stream_id = ?
            """,
            arguments: [threadId.uuidString, streamId.uuidString]
        ).flatMap(Self.decodeStreamThread)
    }

    private func fetchConversationAnchors(streamId: UUID, db: Database) throws -> [ConversationAnchor] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT thread_id, anchor_start, anchor_end, anchor_text,
                       detached, ephemeral, updated_at
                FROM stream_threads
                WHERE stream_id = ?
                ORDER BY updated_at DESC, thread_id
            """,
            arguments: [streamId.uuidString]
        ).compactMap { row in
            guard let threadId = UUID(uuidString: row["thread_id"]) else { return nil }
            return ConversationAnchor(
                threadId: threadId,
                anchorStart: row["anchor_start"],
                anchorEnd: row["anchor_end"],
                anchorText: row["anchor_text"],
                detached: row["detached"],
                ephemeral: row["ephemeral"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    private func updateConversationAnchors(
        streamId: UUID,
        anchors: [ConversationAnchorUpdate],
        db: Database
    ) throws {
        guard Set(anchors.map(\.threadId)).count == anchors.count else {
            throw StreamThreadPersistenceError.invalidAnchor
        }
        for anchor in anchors {
            guard anchor.anchorStart >= 0,
                  anchor.anchorEnd >= anchor.anchorStart,
                  anchor.detached || anchor.anchorEnd > anchor.anchorStart else {
                throw StreamThreadPersistenceError.invalidAnchor
            }
            try db.execute(
                sql: """
                    UPDATE stream_threads
                    SET anchor_start = ?, anchor_end = ?, detached = ?
                    WHERE thread_id = ? AND stream_id = ?
                """,
                arguments: [
                    anchor.anchorStart,
                    anchor.anchorEnd,
                    anchor.detached,
                    anchor.threadId.uuidString,
                    streamId.uuidString
                ]
            )
            if db.changesCount != 1 {
                DebugLog.log(
                    "[Persistence] Skipped missing conversation anchor \(anchor.threadId) for stream \(streamId)"
                )
            }
        }
    }

    private static func decodeStreamThread(_ row: Row) -> StreamThread? {
        guard let threadId = UUID(uuidString: row["thread_id"]),
              let streamId = UUID(uuidString: row["stream_id"]) else {
            return nil
        }
        let sourceIdRaw: String? = row["source_id"]
        let highlightIdRaw: String? = row["highlight_id"]
        return StreamThread(
            threadId: threadId,
            streamId: streamId,
            title: row["title"],
            workingText: row["working_text"],
            docJSON: row["doc_json"],
            docFormatVersion: row["doc_format_version"],
            anchorText: row["anchor_text"],
            anchorSpanId: row["anchor_span_id"],
            sourceId: sourceIdRaw.flatMap(UUID.init(uuidString:)),
            highlightId: highlightIdRaw.flatMap(UUID.init(uuidString:)),
            anchorStart: row["anchor_start"],
            anchorEnd: row["anchor_end"],
            detached: row["detached"],
            ephemeral: row["ephemeral"],
            profile: row["profile"],
            revision: row["revision"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    // MARK: - Provenance Operations

    func loadSpans(streamId: UUID) throws -> [ProvenanceSpan] {
        try dbQueue.read { db in
            try fetchSpans(streamId: streamId, db: db)
        }
    }

    func replaceSpans(streamId: UUID, spans: [ProvenanceSpan]) throws {
        try dbQueue.write { db in
            try replaceSpans(streamId: streamId, spans: spans, db: db)
        }
    }

    func loadExchange(requestId: String) throws -> AIExchange? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT request_id, stream_id, thread_id, verb, user_input,
                           source_manifest, response_raw, model, thread_disposition, created_at
                    FROM ai_exchanges
                    WHERE request_id = ?
                """,
                arguments: [requestId]
            ).flatMap(Self.decodeExchange)
        }
    }

    func recordThreadToolApplication(
        requestId: String,
        streamId: UUID,
        before: String,
        applied: Bool,
        failure: String?
    ) throws -> AIExchange {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT request_id, stream_id, thread_id, verb, user_input,
                           source_manifest, response_raw, model, thread_disposition, created_at
                    FROM ai_exchanges
                    WHERE request_id = ? AND stream_id = ? AND thread_id IS NOT NULL
                """,
                arguments: [requestId, streamId.uuidString]
            ),
            let exchange = Self.decodeExchange(row),
            let data = exchange.sourceManifest.data(using: .utf8),
            var receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var updateBlock = receipt["updateBlock"] as? [String: Any],
            updateBlock["after"] is String else {
                throw StreamThreadPersistenceError.exchangeOutsideThread
            }
            updateBlock["before"] = before
            updateBlock["applied"] = applied
            updateBlock["failure"] = failure ?? NSNull()
            receipt["updateBlock"] = updateBlock
            // Receipt identity is semantic, not JSON key order; sorting only stabilizes stored/debug output.
            let manifestData = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            let sourceManifest = String(decoding: manifestData, as: UTF8.self)
            try db.execute(
                sql: "UPDATE ai_exchanges SET source_manifest = ? WHERE request_id = ?",
                arguments: [sourceManifest, requestId]
            )
            return AIExchange(
                requestId: exchange.requestId,
                streamId: exchange.streamId,
                threadId: exchange.threadId,
                verb: exchange.verb,
                userInput: exchange.userInput,
                sourceManifest: sourceManifest,
                responseRaw: exchange.responseRaw,
                model: exchange.model,
                threadDisposition: exchange.threadDisposition,
                createdAt: exchange.createdAt
            )
        }
    }

    func saveExchange(_ exchange: AIExchange) throws {
        try dbQueue.write { db in
            try saveExchange(exchange, db: db)
        }
    }

    private func saveExchange(_ exchange: AIExchange, db: Database) throws {
        if let threadId = exchange.threadId {
            guard try Row.fetchOne(
                db,
                sql: "SELECT thread_id FROM stream_threads WHERE thread_id = ? AND stream_id = ?",
                arguments: [threadId.uuidString, exchange.streamId.uuidString]
            ) != nil else {
                throw StreamThreadPersistenceError.threadNotFound
            }
        }

        try db.execute(
            sql: """
                INSERT INTO ai_exchanges
                    (request_id, stream_id, thread_id, verb, user_input, source_manifest,
                     response_raw, model, thread_disposition, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(request_id) DO UPDATE SET
                    stream_id = excluded.stream_id,
                    thread_id = excluded.thread_id,
                    verb = excluded.verb,
                    user_input = excluded.user_input,
                    source_manifest = excluded.source_manifest,
                    response_raw = excluded.response_raw,
                    model = excluded.model,
                    thread_disposition = excluded.thread_disposition,
                    created_at = excluded.created_at
            """,
            arguments: [
                exchange.requestId,
                exchange.streamId.uuidString,
                exchange.threadId?.uuidString,
                exchange.verb,
                exchange.userInput,
                exchange.sourceManifest,
                exchange.responseRaw,
                exchange.model,
                exchange.threadDisposition,
                exchange.createdAt.timeIntervalSince1970
            ]
        )

        if let threadId = exchange.threadId {
            let updatedAt = exchange.createdAt.timeIntervalSince1970
            try db.execute(
                sql: "UPDATE stream_threads SET updated_at = MAX(updated_at, ?) WHERE thread_id = ?",
                arguments: [updatedAt, threadId.uuidString]
            )
            try db.execute(
                sql: "UPDATE streams SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                arguments: [updatedAt, exchange.streamId.uuidString]
            )
        }
    }

    private static func decodeExchange(_ row: Row) -> AIExchange? {
        guard let streamId = UUID(uuidString: row["stream_id"]) else {
            return nil
        }
        let threadIdRaw: String? = row["thread_id"]
        return AIExchange(
            requestId: row["request_id"],
            streamId: streamId,
            threadId: threadIdRaw.flatMap(UUID.init(uuidString:)),
            verb: row["verb"],
            userInput: row["user_input"],
            sourceManifest: row["source_manifest"],
            responseRaw: row["response_raw"],
            model: row["model"],
            threadDisposition: row["thread_disposition"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    func deleteOrphanExchanges(streamId: UUID) throws {
        try dbQueue.write { db in
            try deleteOrphanExchanges(streamId: streamId, db: db)
        }
    }

    private func deleteOrphanExchanges(streamId: UUID, db: Database) throws {
        // Grace window: an exchange is saved when streaming completes, but its
        // referencing span only reaches the DB with the editor's next autosave.
        // Any save landing in that gap must not GC the brand-new exchange.
        let graceCutoff = Date().timeIntervalSince1970 - 300
        try db.execute(
            sql: """
                DELETE FROM ai_exchanges
                WHERE stream_id = ?
                  AND created_at < ?
                  AND thread_id IS NULL
                  AND NOT EXISTS (
                    SELECT 1
                    FROM provenance_spans
                    WHERE provenance_spans.request_id = ai_exchanges.request_id
                  )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM margin_notes
                    WHERE margin_notes.request_id = ai_exchanges.request_id
                  )
            """,
            arguments: [streamId.uuidString, graceCutoff]
        )
    }

    private func fetchSpans(streamId: UUID, db: Database) throws -> [ProvenanceSpan] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT span_id, stream_id, start, end, origin, request_id, source_id, meta, text_hash, created_at
                FROM provenance_spans
                WHERE stream_id = ?
                ORDER BY start, end, span_id
            """,
            arguments: [streamId.uuidString]
        ).map { row in
            ProvenanceSpan(
                spanId: row["span_id"],
                streamId: UUID(uuidString: row["stream_id"]) ?? streamId,
                start: row["start"],
                end: row["end"],
                origin: row["origin"],
                requestId: row["request_id"],
                sourceId: row["source_id"],
                meta: row["meta"],
                textHash: row["text_hash"],
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    private func replaceSpans(streamId: UUID, spans: [ProvenanceSpan], db: Database) throws {
        try db.execute(
            sql: "DELETE FROM provenance_spans WHERE stream_id = ?",
            arguments: [streamId.uuidString]
        )
        try insertSpans(streamId: streamId, spans: spans, db: db)
    }

    private func insertSpans(streamId: UUID, spans: [ProvenanceSpan], db: Database) throws {
        for span in spans {
            try db.execute(
                sql: """
                    INSERT INTO provenance_spans
                        (span_id, stream_id, start, end, origin, request_id, source_id, meta, text_hash, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    span.spanId,
                    streamId.uuidString,
                    span.start,
                    span.end,
                    span.origin,
                    span.requestId,
                    span.sourceId,
                    span.meta,
                    span.textHash,
                    span.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    /// Provenance coordinates are ProseMirror document positions, not offsets into
    /// the Markdown. They keep the `start`/`end` column names — the same integers,
    /// measured against the document rather than against its serialisation — so
    /// there is no way to tell an old row from a new one by looking, and migration
    /// v24 clears the table rather than guessing.
    ///
    /// This can therefore no longer check the text a span covers: slicing Markdown
    /// by a document position is meaningless, and hashing that slice silently
    /// dropped EVERY span. A span over `bold` in `**bold**` hashed `*bol`. The
    /// editor owns that check now, because only the editor has the document; what
    /// is left here is the structural check, which still catches a malformed
    /// payload.
    private func validatedSpans(_ spans: [ProvenanceSpan], streamId: UUID) -> [ProvenanceSpan] {
        spans.compactMap { span in
            guard span.start >= 0, span.start < span.end else {
                return nil
            }

            return ProvenanceSpan(
                spanId: span.spanId,
                streamId: streamId,
                start: span.start,
                end: span.end,
                origin: span.origin,
                requestId: span.requestId,
                sourceId: span.sourceId,
                meta: span.meta,
                textHash: span.textHash,
                createdAt: span.createdAt
            )
        }
    }

    /// The append's spans, verbatim, as offsets into its own fragment. Stored as
    /// JSON rather than as columns because nothing here interprets them — they are
    /// carried to an editor and converted there.
    private static func encodeRawSpans(_ spans: [ProvenanceSpan]) -> String {
        let rows: [[String: Any]] = spans.map { span in
            var row: [String: Any] = [
                "spanId": span.spanId,
                "start": span.start,
                "end": span.end,
                "origin": span.origin,
                "meta": span.meta,
                "textHash": span.textHash,
                "createdAt": ISO8601DateFormatter().string(from: span.createdAt)
            ]
            if let requestId = span.requestId { row["requestId"] = requestId }
            if let sourceId = span.sourceId { row["sourceId"] = sourceId }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Appends this stream has recorded but no editor has converted yet.
    func loadPendingAppends(streamId: UUID) throws -> [PendingStreamAppend] {
        try dbQueue.read { db in
            try fetchPendingAppends(streamId: streamId, db: db)
        }
    }

    private func fetchPendingAppends(streamId: UUID, db: Database) throws -> [PendingStreamAppend] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT revision, separator, fragment, raw_spans_json
                FROM pending_stream_appends
                WHERE stream_id = ?
                ORDER BY revision ASC
            """,
            arguments: [streamId.uuidString]
        ).map { row in
            PendingStreamAppend(
                revision: row["revision"],
                separator: row["separator"],
                fragment: row["fragment"],
                rawSpansJSON: row["raw_spans_json"]
            )
        }
    }

    /// Forget the appends whose provenance an editor has just converted.
    ///
    /// Gated on the editor SAYING which revisions it resolved, never on a save
    /// merely carrying spans: an editor that does not understand pending rows also
    /// sends spans, and deleting rows it never converted destroys the provenance
    /// permanently. Nothing beyond the save's own base revision is cleared either,
    /// since anything later arrived after the editor read the document.
    private func clearResolvedPendingAppends(
        streamId: UUID,
        through: Int?,
        baseRevision: Int,
        db: Database
    ) throws {
        guard let through, through > 0 else { return }
        try db.execute(
            sql: "DELETE FROM pending_stream_appends WHERE stream_id = ? AND revision <= ?",
            arguments: [streamId.uuidString, min(through, baseRevision)]
        )
    }

    private func fetchAppendInbox(
        streamId: UUID,
        db: Database
    ) throws -> [StreamAppendInboxEntry] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT seq, append_id, fragment, raw_spans_json, created_at
                FROM stream_append_inbox
                WHERE stream_id = ? AND consumed_at IS NULL
                ORDER BY seq ASC
            """,
            arguments: [streamId.uuidString]
        ).map { row in
            StreamAppendInboxEntry(
                seq: row["seq"],
                appendId: row["append_id"],
                fragment: row["fragment"],
                rawSpansJSON: row["raw_spans_json"],
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    /**
     * A save may race a later producer row that its watermark does not include.
     * Leaving that durable row out of the projection makes search and AI observe a
     * document state that never existed until the editor next opens and reduces it.
     */
    private func markdownProjectionIncludingInbox(
        _ markdown: String,
        streamId: UUID,
        db: Database
    ) throws -> String {
        ([markdown] + (try fetchAppendInbox(streamId: streamId, db: db)).map(\.fragment))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /**
     * Delete only a watermark that belongs to this stream right now. Without the
     * ownership proof, one typo can consume every older row while the document
     * save succeeds, leaving those captures nowhere.
     */
    private func clearConsumedAppendInbox(
        streamId: UUID,
        through: Int?,
        db: Database
    ) throws {
        guard let through else { return }
        guard through > 0,
              try Int.fetchOne(
                db,
                sql: """
                    SELECT seq FROM stream_append_inbox
                    WHERE stream_id = ? AND seq = ? AND consumed_at IS NULL
                """,
                arguments: [streamId.uuidString, through]
              ) != nil else {
            throw PersistenceError.encodingFailed("Invalid append inbox watermark")
        }
        try db.execute(
            sql: """
                UPDATE stream_append_inbox
                SET consumed_at = ?
                WHERE stream_id = ? AND seq <= ? AND consumed_at IS NULL
            """,
            arguments: [Date().timeIntervalSince1970, streamId.uuidString, through]
        )
    }

    private func logDroppedSpans(total: Int, kept: Int, context: String) {
        let dropped = total - kept
        guard dropped > 0 else { return }
        DebugLog.log("[Persistence] Dropped \(dropped) invalid provenance span(s) during \(context)")
    }

    // MARK: - Margin Note Operations

    func loadMarginNotes(streamId: UUID, statuses: [String]? = ["open", "unanchored"]) throws -> [MarginNote] {
        try dbQueue.read { db in
            try fetchMarginNotes(streamId: streamId, statuses: statuses, db: db)
        }
    }

    func insertMarginNotes(_ notes: [MarginNote]) throws {
        try dbQueue.write { db in
            try insertMarginNotes(notes, db: db)
        }
    }

    @discardableResult
    func updateMarginNoteStatus(noteId: String, status: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE margin_notes SET status = ? WHERE note_id = ?",
                arguments: [status, noteId]
            )
            return db.changesCount > 0
        }
    }

    func deleteMarginNote(noteId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM margin_notes WHERE note_id = ?",
                arguments: [noteId]
            )
        }
    }

    func insertMarginSuppression(streamId: UUID, bodyHash: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO margin_suppressions (stream_id, body_hash)
                    VALUES (?, ?)
                """,
                arguments: [streamId.uuidString, bodyHash]
            )
        }
    }

    func updateMarginNoteStatusAndLoadVisible(noteId: String, status: String) throws -> (streamId: UUID, notes: [MarginNote])? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT stream_id, body_hash FROM margin_notes WHERE note_id = ?",
                arguments: [noteId]
            ),
                  let streamId = UUID(uuidString: row["stream_id"] as String) else {
                return nil
            }

            try db.execute(
                sql: "UPDATE margin_notes SET status = ? WHERE note_id = ?",
                arguments: [status, noteId]
            )

            if status == "dismissed" {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO margin_suppressions (stream_id, body_hash)
                        VALUES (?, ?)
                    """,
                    arguments: [streamId.uuidString, row["body_hash"] as String]
                )
            }

            return (streamId, try fetchMarginNotes(streamId: streamId, statuses: ["open", "unanchored"], db: db))
        }
    }

    func marginSuppressionHashes(streamId: UUID) throws -> Set<String> {
        try dbQueue.read { db in
            try Set(Row.fetchAll(
                db,
                sql: "SELECT body_hash FROM margin_suppressions WHERE stream_id = ?",
                arguments: [streamId.uuidString]
            ).map { row in row["body_hash"] as String })
        }
    }

    func nonDismissedMarginNoteBodyHashes(streamId: UUID) throws -> Set<String> {
        try dbQueue.read { db in
            try Set(Row.fetchAll(
                db,
                sql: """
                    SELECT body_hash
                    FROM margin_notes
                    WHERE stream_id = ? AND status != 'dismissed'
                """,
                arguments: [streamId.uuidString]
            ).map { row in row["body_hash"] as String })
        }
    }

    private func fetchMarginNotes(streamId: UUID, statuses: [String]?, db: Database) throws -> [MarginNote] {
        var sql = """
            SELECT note_id, stream_id, anchor_start, anchor_end, anchor_hash, kind, body, body_hash, request_id, status, created_at
            FROM margin_notes
            WHERE stream_id = ?
        """
        var arguments: StatementArguments = [streamId.uuidString]
        if let statuses {
            guard !statuses.isEmpty else { return [] }
            sql += " AND status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ",")))"
            for status in statuses {
                arguments += [status]
            }
        }
        sql += " ORDER BY anchor_start, created_at, note_id"

        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            MarginNote(
                noteId: row["note_id"],
                streamId: UUID(uuidString: row["stream_id"]) ?? streamId,
                anchorStart: row["anchor_start"],
                anchorEnd: row["anchor_end"],
                anchorHash: row["anchor_hash"],
                kind: row["kind"],
                body: row["body"],
                bodyHash: row["body_hash"],
                requestId: row["request_id"],
                status: row["status"],
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    private func insertMarginNotes(_ notes: [MarginNote], db: Database) throws {
        for note in notes {
            try db.execute(
                sql: """
                    INSERT INTO margin_notes
                        (note_id, stream_id, anchor_start, anchor_end, anchor_hash, kind, body, body_hash, request_id, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    note.noteId,
                    note.streamId.uuidString,
                    note.anchorStart,
                    note.anchorEnd,
                    note.anchorHash,
                    note.kind,
                    note.body,
                    note.bodyHash,
                    note.requestId,
                    note.status,
                    note.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    // MARK: - Source Operations

    func loadSource(id: UUID) throws -> SourceReference? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }

            let embeddingStatusRaw: String? = row["embedding_status"]
            let embeddingStatus = embeddingStatusRaw.flatMap(SourceEmbeddingStatus.init(rawValue:)) ?? .none
            let indexStatusRaw: String? = row["index_status"]
            let indexStatus = indexStatusRaw.flatMap(SourceIndexStatus.init(rawValue:)) ?? .pending
            let aiExcluded: Int = row["ai_excluded"]

            return SourceReference(
                id: UUID(uuidString: row["id"])!,
                streamId: UUID(uuidString: row["stream_id"])!,
                displayName: row["display_name"],
                fileType: SourceFileType(rawValue: row["file_type"]) ?? .text,
                bookmarkData: row["bookmark_data"],
                originalPath: row["original_path"],
                status: SourceStatus(rawValue: row["status"]) ?? .pending,
                extractedText: row["extracted_text"],
                pageCount: row["page_count"],
                embeddingStatus: embeddingStatus,
                indexStatus: indexStatus,
                aiExcluded: aiExcluded != 0,
                lastPageIndex: row["last_page_index"],
                addedAt: Date(timeIntervalSince1970: row["added_at"])
            )
        }
    }

    func saveSource(_ source: SourceReference) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sources (id, stream_id, display_name, file_type, bookmark_data, original_path, status, extracted_text, page_count, index_status, ai_excluded, added_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        bookmark_data = excluded.bookmark_data,
                        original_path = excluded.original_path,
                        status = excluded.status,
                        extracted_text = excluded.extracted_text,
                        page_count = excluded.page_count,
                        index_status = excluded.index_status,
                        ai_excluded = excluded.ai_excluded
                """,
                arguments: [
                    source.id.uuidString,
                    source.streamId.uuidString,
                    source.displayName,
                    source.fileType.rawValue,
                    source.bookmarkData,
                    source.originalPath,
                    source.status.rawValue,
                    source.extractedText,
                    source.pageCount,
                    source.indexStatus.rawValue,
                    source.aiExcluded ? 1 : 0,
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

    func setSourceAIExcluded(_ sourceId: UUID, excluded: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sources SET ai_excluded = ? WHERE id = ?",
                arguments: [excluded ? 1 : 0, sourceId.uuidString]
            )
        }
    }

    func updateSourceExtraction(
        _ sourceId: UUID,
        text: String?,
        pageCount: Int?,
        status: SourceStatus
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sources SET extracted_text = ?, page_count = ?, status = ? WHERE id = ?",
                arguments: [text, pageCount, status.rawValue, sourceId.uuidString]
            )
        }
    }

    func saveSourceLastPageIndex(sourceId: UUID, pageIndex: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sources SET last_page_index = ? WHERE id = ?",
                arguments: [max(0, pageIndex), sourceId.uuidString]
            )
        }
    }

    func deleteSource(id: UUID) throws {
        try dbQueue.write { db in
            try deleteChunksForSource(id, db: db)
            try db.execute(sql: "DELETE FROM pdf_highlights WHERE source_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - PDF Highlight Operations

    func savePDFHighlight(_ highlight: PDFHighlightRecord) throws {
        try dbQueue.write { db in
            try savePDFHighlight(highlight, db: db)
        }
    }

    private func savePDFHighlight(_ highlight: PDFHighlightRecord, db: Database) throws {
        let rectsData = try JSONEncoder().encode(highlight.rects)
        guard let rectsJSON = String(data: rectsData, encoding: .utf8) else {
            throw PersistenceError.encodingFailed("Could not encode PDF highlight rects.")
        }

        try db.execute(
            sql: """
                INSERT INTO pdf_highlights (id, source_id, page, rects_json, quote, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    page = excluded.page,
                    rects_json = excluded.rects_json,
                    quote = excluded.quote,
                    created_at = excluded.created_at
            """,
            arguments: [
                highlight.id.uuidString,
                highlight.sourceId.uuidString,
                highlight.page,
                rectsJSON,
                highlight.quote,
                Self.pdfHighlightDateFormatter.string(from: highlight.createdAt)
            ]
        )
    }

    @discardableResult
    func deletePDFHighlight(id: UUID, streamId: UUID) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM pdf_highlights
                    WHERE id = ?
                      AND source_id IN (SELECT id FROM sources WHERE stream_id = ?)
                """,
                arguments: [id.uuidString, streamId.uuidString]
            )
            return db.changesCount > 0
        }
    }

    func loadPDFHighlights(sourceId: UUID) throws -> [PDFHighlightRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_id, page, rects_json, quote, created_at
                    FROM pdf_highlights
                    WHERE source_id = ?
                    ORDER BY created_at ASC
                """,
                arguments: [sourceId.uuidString]
            )

            return try rows.map { row in
                try decodePDFHighlight(row)
            }
        }
    }

    func loadPDFHighlight(id: UUID, sourceId: UUID) throws -> PDFHighlightRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source_id, page, rects_json, quote, created_at
                    FROM pdf_highlights
                    WHERE id = ? AND source_id = ?
                """,
                arguments: [id.uuidString, sourceId.uuidString]
            ).map { try decodePDFHighlight($0) }
        }
    }

    private func decodePDFHighlight(_ row: Row) throws -> PDFHighlightRecord {
        let rectsJSON: String = row["rects_json"]
        guard let rectsData = rectsJSON.data(using: .utf8) else {
            throw PersistenceError.encodingFailed("Could not read PDF highlight rects.")
        }
        let rects = try JSONDecoder().decode([PDFHighlightRect].self, from: rectsData)
        let createdAtValue: String = row["created_at"]
        let createdAt = Self.pdfHighlightDateFormatter.date(from: createdAtValue) ?? Date(timeIntervalSince1970: 0)

        return PDFHighlightRecord(
            id: UUID(uuidString: row["id"])!,
            sourceId: UUID(uuidString: row["source_id"])!,
            page: row["page"],
            rects: rects,
            quote: row["quote"],
            createdAt: createdAt
        )
    }

    private static func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return html
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownishTextFromLegacyCellHTML(_ html: String) -> String {
        let rewrittenHTML = rewriteImageTagsToMarkdown(html)
        return htmlToPlainText(rewrittenHTML).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rewriteImageTagsToMarkdown(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return html
        }

        let original = html as NSString
        let result = NSMutableString(string: html)
        let fullRange = NSRange(location: 0, length: original.length)

        for match in regex.matches(in: html, range: fullRange).reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let src = original.substring(with: match.range(at: 2))
            result.replaceCharacters(in: match.range, with: "![capture](\(src))")
        }

        return result as String
    }

    // MARK: - Source Chunk Index Operations

    func saveSourceChunks(_ chunks: [SourceChunk], for sourceId: UUID) throws {
        try dbQueue.write { db in
            try deleteChunksForSource(sourceId, db: db)

            for chunk in chunks {
                try db.execute(
                    sql: """
                        INSERT INTO source_chunks (id, source_id, seq, text, page_start, page_end, section_path)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id.uuidString,
                        sourceId.uuidString,
                        chunk.seq,
                        chunk.text,
                        chunk.pageStart,
                        chunk.pageEnd,
                        chunk.sectionPath
                    ]
                )

                try db.execute(
                    sql: """
                        INSERT INTO source_chunks_fts (chunk_id, source_id, text)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [
                        chunk.id.uuidString,
                        sourceId.uuidString,
                        chunk.text
                    ]
                )
            }
        }
    }

    func loadSourceChunks(sourceId: UUID) throws -> [SourceChunk] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_id, seq, text, page_start, page_end, section_path
                    FROM source_chunks
                    WHERE source_id = ?
                    ORDER BY seq
                """,
                arguments: [sourceId.uuidString]
            ).map(Self.decodeSourceChunk)
        }
    }

    func loadSourceChunk(id: UUID) throws -> SourceChunk? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source_id, seq, text, page_start, page_end, section_path
                    FROM source_chunks
                    WHERE id = ?
                """,
                arguments: [id.uuidString]
            ).map(Self.decodeSourceChunk)
        }
    }

    func loadChunksMissingEmbeddings(streamId: UUID, modelId: String) throws -> [SourceChunk] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.source_id, c.seq, c.text, c.page_start, c.page_end, c.section_path
                    FROM source_chunks c
                    JOIN sources s ON s.id = c.source_id
                    LEFT JOIN chunk_embeddings e ON e.chunk_id = c.id AND e.model_id = ?
                    WHERE s.stream_id = ? AND s.index_status = 'ready' AND e.chunk_id IS NULL
                    ORDER BY c.source_id, c.seq
                """,
                arguments: [modelId, streamId.uuidString]
            ).map(Self.decodeSourceChunk)
        }
    }

    func saveChunkEmbeddings(_ vectors: [[Float]], for chunks: [SourceChunk], modelId: String) throws {
        guard vectors.count == chunks.count else { return }
        try dbQueue.write { db in
            for (chunk, vector) in zip(chunks, vectors) {
                let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO chunk_embeddings (chunk_id, model_id, dims, vector)
                        VALUES (?, ?, ?, ?)
                    """,
                    arguments: [chunk.id.uuidString, modelId, vector.count, data]
                )
            }
        }
    }

    func loadChunkEmbeddings(
        streamId: UUID,
        modelId: String,
        excludeAIPrivateSources: Bool = true
    ) throws -> [(chunk: RetrievedChunk, vector: [Float])] {
        let aiExclusionPredicate = excludeAIPrivateSources ? "AND s.ai_excluded = 0" : ""
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.source_id, s.display_name AS source_name, c.seq, c.text,
                           c.page_start, c.page_end, c.section_path, e.dims, e.vector
                    FROM chunk_embeddings e
                    JOIN source_chunks c ON c.id = e.chunk_id
                    JOIN sources s ON s.id = c.source_id
                    WHERE s.stream_id = ? AND e.model_id = ? \(aiExclusionPredicate)
                    ORDER BY c.source_id, c.seq
                """,
                arguments: [streamId.uuidString, modelId]
            ).compactMap { row in
                let dims: Int = row["dims"]
                let data: Data = row["vector"]
                guard dims > 0, data.count == dims * MemoryLayout<Float>.size else { return nil }
                var vector = [Float](repeating: 0, count: dims)
                _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                return (
                    RetrievedChunk(
                        id: UUID(uuidString: row["id"])!,
                        sourceId: UUID(uuidString: row["source_id"])!,
                        sourceName: row["source_name"], seq: row["seq"], text: row["text"],
                        pageStart: row["page_start"], pageEnd: row["page_end"],
                        sectionPath: row["section_path"], score: .greatestFiniteMagnitude,
                        semanticMatch: true
                    ),
                    vector
                )
            }
        }
    }

    func searchSourceChunks(
        matching ftsQuery: String,
        streamId: UUID,
        limit: Int,
        excludeAIPrivateSources: Bool = true,
        requiringAtLeastTwoOf queryTerms: [String]? = nil
    ) throws -> [RetrievedChunk] {
        let aiExclusionPredicate = excludeAIPrivateSources ? "AND s.ai_excluded = 0" : ""

        return try dbQueue.read { db in
            let chunkIDs: Set<UUID>?
            if let queryTerms {
                var counts: [UUID: Int] = [:]
                for term in Set(queryTerms) {
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT c.id
                            FROM source_chunks_fts
                            JOIN source_chunks c ON c.id = source_chunks_fts.chunk_id
                            JOIN sources s ON s.id = c.source_id
                            WHERE source_chunks_fts MATCH ?
                              AND s.stream_id = ?
                              \(aiExclusionPredicate)
                        """,
                        arguments: ["\"\(term)\"", streamId.uuidString]
                    )
                    for row in rows {
                        guard let id = UUID(uuidString: row["id"]) else { continue }
                        counts[id, default: 0] += 1
                    }
                }
                chunkIDs = Set(counts.compactMap { $0.value >= 2 ? $0.key : nil })
            } else {
                chunkIDs = nil
            }
            if chunkIDs?.isEmpty == true { return [] }

            let sortedChunkIDs = chunkIDs?.sorted { $0.uuidString < $1.uuidString }
            let chunkPredicate = sortedChunkIDs.map {
                "AND c.id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))"
            } ?? ""
            var arguments: StatementArguments = [ftsQuery, streamId.uuidString]
            for id in sortedChunkIDs ?? [] { arguments += [id.uuidString] }
            arguments += [limit]

            return try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.id,
                        c.source_id,
                        s.display_name AS source_name,
                        c.seq,
                        c.text,
                        c.page_start,
                        c.page_end,
                        c.section_path,
                        bm25(source_chunks_fts) AS score
                    FROM source_chunks_fts
                    JOIN source_chunks c ON c.id = source_chunks_fts.chunk_id
                    JOIN sources s ON s.id = c.source_id
                    WHERE source_chunks_fts MATCH ?
                      AND s.stream_id = ?
                      \(aiExclusionPredicate)
                      \(chunkPredicate)
                    ORDER BY score ASC
                    LIMIT ?
                """,
                arguments: arguments
            ).map { row in
                RetrievedChunk(
                    id: UUID(uuidString: row["id"])!,
                    sourceId: UUID(uuidString: row["source_id"])!,
                    sourceName: row["source_name"],
                    seq: row["seq"],
                    text: row["text"],
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    sectionPath: row["section_path"],
                    score: row["score"]
                )
            }
        }
    }

    func searchSourceChunksGlobally(
        matching ftsQuery: String,
        excludingStreamId: UUID? = nil,
        limit: Int,
        excludeAIPrivateSources: Bool = true
    ) throws -> [GlobalSourceChunkMatch] {
        let streamPredicate = excludingStreamId == nil ? "" : "AND s.stream_id <> ?"
        let aiExclusionPredicate = excludeAIPrivateSources ? "AND s.ai_excluded = 0" : ""
        var arguments: StatementArguments = [ftsQuery]
        if let excludingStreamId { arguments += [excludingStreamId.uuidString] }
        arguments += [limit]

        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.id,
                        c.source_id,
                        s.display_name AS source_name,
                        s.stream_id,
                        streams.title AS stream_title,
                        c.seq,
                        c.text,
                        c.page_start,
                        c.page_end,
                        c.section_path,
                        bm25(source_chunks_fts) AS score
                    FROM source_chunks_fts
                    JOIN source_chunks c ON c.id = source_chunks_fts.chunk_id
                    JOIN sources s ON s.id = c.source_id
                    JOIN streams ON streams.id = s.stream_id
                    WHERE source_chunks_fts MATCH ?
                      \(streamPredicate)
                      \(aiExclusionPredicate)
                    ORDER BY score ASC
                    LIMIT ?
                """,
                arguments: arguments
            ).map { row in
                GlobalSourceChunkMatch(
                    streamId: UUID(uuidString: row["stream_id"])!,
                    streamTitle: row["stream_title"],
                    chunk: RetrievedChunk(
                        id: UUID(uuidString: row["id"])!,
                        sourceId: UUID(uuidString: row["source_id"])!,
                        sourceName: row["source_name"],
                        seq: row["seq"],
                        text: row["text"],
                        pageStart: row["page_start"],
                        pageEnd: row["page_end"],
                        sectionPath: row["section_path"],
                        score: row["score"]
                    )
                )
            }
        }
    }

    func deleteChunksForSource(_ sourceId: UUID) throws {
        try dbQueue.write { db in
            try deleteChunksForSource(sourceId, db: db)
        }
    }

    func updateSourceIndexStatus(_ sourceId: UUID, status: SourceIndexStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sources SET index_status = ? WHERE id = ?",
                arguments: [status.rawValue, sourceId.uuidString]
            )
        }
    }

    func loadSourceIndexStatuses(streamId: UUID) throws -> [UUID: SourceIndexStatus] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, index_status
                    FROM sources
                    WHERE stream_id = ?
                """,
                arguments: [streamId.uuidString]
            )

            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let raw: String = row["index_status"]
                return (id, SourceIndexStatus(rawValue: raw) ?? .pending)
            })
        }
    }

    private func deleteChunksForSource(_ sourceId: UUID, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM source_chunks_fts WHERE source_id = ?",
            arguments: [sourceId.uuidString]
        )
        try db.execute(
            sql: "DELETE FROM source_chunks WHERE source_id = ?",
            arguments: [sourceId.uuidString]
        )
    }

    private static func decodeSourceChunk(_ row: Row) -> SourceChunk {
        SourceChunk(
            id: UUID(uuidString: row["id"])!,
            sourceId: UUID(uuidString: row["source_id"])!,
            seq: row["seq"],
            text: row["text"],
            pageStart: row["page_start"],
            pageEnd: row["page_end"],
            sectionPath: row["section_path"]
        )
    }

    // MARK: - Text Search

    /// Search stream documents by text, returning results split by current vs other streams.
    /// Each stream category gets its own limit to ensure cross-stream coverage.
    /// With no current stream (e.g. searching from the stream list) every match lands in `otherStreams`.
    func textSearchStreamDocuments(
        query: String,
        currentStreamId: UUID?,
        limitPerCategory: Int = 15
    ) throws -> (currentStream: [StreamDocumentSearchResult], otherStreams: [StreamDocumentSearchResult]) {
        // Escape SQL LIKE special characters to prevent injection
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        return try dbQueue.read { db in
            // Search current stream
            let currentResults = try Row.fetchAll(db, sql: """
                SELECT d.stream_id, s.title as stream_title, d.markdown, d.updated_at
                FROM stream_documents d
                JOIN streams s ON d.stream_id = s.id
                WHERE d.stream_id = ?
                  AND d.markdown LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY d.updated_at DESC
                LIMIT ?
            """, arguments: [currentStreamId?.uuidString ?? "", pattern, limitPerCategory])
            .map { row in
                StreamDocumentSearchResult(
                    streamId: UUID(uuidString: row["stream_id"])!,
                    streamTitle: row["stream_title"],
                    markdown: row["markdown"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }

            // Search other streams
            let otherResults = try Row.fetchAll(db, sql: """
                SELECT d.stream_id, s.title as stream_title, d.markdown, d.updated_at
                FROM stream_documents d
                JOIN streams s ON d.stream_id = s.id
                WHERE d.stream_id != ?
                  AND d.markdown LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY d.updated_at DESC
                LIMIT ?
            """, arguments: [currentStreamId?.uuidString ?? "", pattern, limitPerCategory])
            .map { row in
                StreamDocumentSearchResult(
                    streamId: UUID(uuidString: row["stream_id"])!,
                    streamTitle: row["stream_title"],
                    markdown: row["markdown"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }

            return (currentResults, otherResults)
        }
    }
}

/// Result from text search on stream documents.
struct StreamDocumentSearchResult {
    let streamId: UUID
    let streamTitle: String
    let markdown: String
    let updatedAt: Date
}
