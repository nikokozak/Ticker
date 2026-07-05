import CoreGraphics
import AppKit
import Foundation
import GRDB
import PDFKit
import XCTest

@testable import Ticker

final class QuickPanelMarkdownFormatterTests: XCTestCase {
    func test_buildFragment_includesSelectedTextAsBlockquoteWithAttribution() throws {
        let context = QuickPanelContext(
            selectedText: " First line\nSecond line ",
            activeApp: "Safari",
            windowTitle: "Article *Title*",
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil,
            isScreenshot: false
        )

        let fragment = try QuickPanelMarkdownFormatter.buildFragment(
            context: context,
            inputText: "Saved note"
        ) { _ in
            XCTFail("Image formatter should not run for text-only context")
            return ""
        }

        XCTAssertEqual(fragment, """
        > First line
        > Second line

        *— Safari — Article \\*Title\\**

        Saved note
        """)
    }

    @MainActor
    func test_localSelectionProviderPrefersPDFSelectionOverEditorSelection() async {
        var editorSelectionWasRequested = false
        let provider = QuickPanelLocalSelectionProvider(
            pdfSelection: { " PDF selection " },
            editorSelection: {
                editorSelectionWasRequested = true
                return "Editor selection"
            }
        )

        let selectedText = await provider.selectedText()

        XCTAssertEqual(selectedText, "PDF selection")
        XCTAssertFalse(editorSelectionWasRequested)
    }

    @MainActor
    func test_localSelectionProviderFallsBackToEditorSelection() async {
        let provider = QuickPanelLocalSelectionProvider(
            pdfSelection: { nil },
            editorSelection: { " Editor selection " }
        )

        let selectedText = await provider.selectedText()

        XCTAssertEqual(selectedText, "Editor selection")
    }

    @MainActor
    func test_selectionResolverUsesLocalSelectionForTickerAndAXForOtherApps() async {
        var axSelectionWasRequested = false
        let tickerSelection = await SelectionReaderService.resolveSelectedText(
            activeBundleId: "com.example.Ticker",
            currentBundleId: "com.example.Ticker",
            localSelection: { "Local selection" },
            axSelection: {
                axSelectionWasRequested = true
                return "AX selection"
            }
        )

        XCTAssertEqual(tickerSelection, "Local selection")
        XCTAssertFalse(axSelectionWasRequested)

        var localSelectionWasRequested = false
        let externalSelection = await SelectionReaderService.resolveSelectedText(
            activeBundleId: "net.kovidgoyal.kitty",
            currentBundleId: "com.example.Ticker",
            localSelection: {
                localSelectionWasRequested = true
                return "Local selection"
            },
            axSelection: { "AX selection" }
        )

        XCTAssertEqual(externalSelection, "AX selection")
        XCTAssertFalse(localSelectionWasRequested)
    }

    func test_selectionCaptureLadderRunsRungsInOrder() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: true,
            axSelection: {
                calls.append("ax")
                return nil
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return nil
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: "Clipboard selection", outcome: .clipboard))
        XCTAssertEqual(calls, ["ax", "hint", "hinted", "clipboard"])
    }

    func test_selectionCaptureLadderShortCircuitsOnFirstSuccess() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: true,
            axSelection: {
                calls.append("ax")
                return "AX selection"
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return "Hinted selection"
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: "AX selection", outcome: .ax))
        XCTAssertEqual(calls, ["ax"])
    }

    func test_selectionCaptureLadderSkipsRungsWithoutPermission() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: false,
            axSelection: {
                calls.append("ax")
                return "AX selection"
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return "Hinted selection"
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: nil, outcome: .noPermission))
        XCTAssertTrue(calls.isEmpty)
    }

    func test_selectionCaptureStatusMapping() {
        XCTAssertEqual(
            QuickPanelStatus.selectionCaptureStatus(for: .noPermission, activeApp: "Chrome"),
            QuickPanelStatus(
                message: "Grant Accessibility permission to capture text selections",
                tone: .warning,
                action: .openAccessibilitySettings
            )
        )
        XCTAssertEqual(
            QuickPanelStatus.selectionCaptureStatus(for: .emptyExternal, activeApp: "Chrome"),
            QuickPanelStatus(
                message: "No text selected in Chrome",
                tone: .info,
                action: nil
            )
        )
        XCTAssertEqual(
            QuickPanelStatus.selectionCaptureStatus(for: .emptyExternal, activeApp: " "),
            QuickPanelStatus(
                message: "No text selected",
                tone: .info,
                action: nil
            )
        )
        XCTAssertNil(QuickPanelStatus.selectionCaptureStatus(for: .internalApp, activeApp: "Ticker"))
        XCTAssertNil(QuickPanelStatus.selectionCaptureStatus(for: .axHinted, activeApp: "Chrome"))
    }

    func test_pasteboardSnapshotRestoresItemsAndTypes() throws {
        let pasteboardName = NSPasteboard.Name("TickerPasteboardSnapshotTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        let binaryType = NSPasteboard.PasteboardType("com.ticker.test.binary")
        let customTextType = NSPasteboard.PasteboardType("com.ticker.test.custom-text")
        let binaryData = Data([0x01, 0x02, 0x03, 0xff])

        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
        }

        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("Original string", forType: .string))
        XCTAssertTrue(firstItem.setData(binaryData, forType: binaryType))

        let secondItem = NSPasteboardItem()
        XCTAssertTrue(secondItem.setString("Custom payload", forType: customTextType))

        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Mutated", forType: .string))

        snapshot.restore(to: pasteboard)

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "Original string")
        XCTAssertEqual(restoredItems[0].data(forType: binaryType), binaryData)
        XCTAssertEqual(restoredItems[1].string(forType: customTextType), "Custom payload")
    }
}

final class StreamDocumentTests: XCTestCase {
    private enum TestPDFError: Error {
        case creationFailed
    }

    private typealias RetrievalChunkFixture = (
        seq: Int,
        text: String,
        pageStart: Int,
        pageEnd: Int,
        sectionPath: String?
    )

    func test_v14MigrationCreatesPDFHighlightsTable() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        XCTAssertNotNil(service)
        service = nil

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        let tableExists = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'pdf_highlights'"
            ) != nil
        }
        let indexExists = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_pdf_highlights_source'"
            ) != nil
        }

        XCTAssertTrue(tableExists)
        XCTAssertTrue(indexExists)
    }

    func test_v15MigrationAddsOriginalPathToSources() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        XCTAssertNotNil(service)
        service = nil

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        let columnExists = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sources)")
                .contains { row in
                    let name: String = row["name"]
                    return name == "original_path"
                }
        }

        XCTAssertTrue(columnExists)
    }

    func test_v16MigrationDropsLegacyChunksAndAddsIndexStatus() throws {
        let streamId = UUID()
        let sourceId = UUID()

        try withSeededV15Database { db in
            try insertStream(db, id: streamId, title: "Legacy Chunks", createdAt: 900)
            try insertV15Source(
                db,
                id: sourceId,
                streamId: streamId,
                displayName: "Legacy.pdf",
                fileType: "pdf",
                pageCount: 2
            )
            try db.execute(
                sql: """
                    INSERT INTO source_chunks (
                        id, source_id, chunk_index, content, token_count, page_start, page_end, embedding_status, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    sourceId.uuidString,
                    4,
                    "Distinct legacy chunk text",
                    6,
                    2,
                    2,
                    "pending",
                    1_000
                ]
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let statuses = try service.loadSourceIndexStatuses(streamId: streamId)
            XCTAssertEqual(statuses[sourceId], .pending)

            let chunks = try service.loadSourceChunks(sourceId: sourceId)
            XCTAssertTrue(chunks.isEmpty)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let chunkColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(source_chunks)").map { row -> String in
                    row["name"]
                }
            }
            XCTAssertEqual(
                chunkColumns,
                ["id", "source_id", "seq", "text", "page_start", "page_end", "section_path"]
            )

            let ftsExists = try dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'source_chunks_fts'"
                ) != nil
            }
            XCTAssertTrue(ftsExists)

            let legacyEmbeddingTableIsGone = try dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'chunk_embeddings'"
                ) == nil
            }
            XCTAssertTrue(legacyEmbeddingTableIsGone)

            let ftsCount: Int = try dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count FROM source_chunks_fts")?["count"] ?? -1
            }
            XCTAssertEqual(ftsCount, 0)
        }
    }

    func test_sourceAIExcludedDefaultsFalseAndRoundTripsThroughPersistence() throws {
        let streamId = UUID()
        let sourceId = UUID()

        try withSeededV15Database { db in
            try insertStream(db, id: streamId, title: "Private Flag", createdAt: 900)
            try insertV15Source(
                db,
                id: sourceId,
                streamId: streamId,
                displayName: "Sensitive.pdf",
                fileType: "pdf",
                pageCount: 2
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            var source = try XCTUnwrap(service.loadSource(id: sourceId))
            XCTAssertFalse(source.aiExcluded)

            try service.setSourceAIExcluded(sourceId, excluded: true)
            source = try XCTUnwrap(service.loadSource(id: sourceId))
            XCTAssertTrue(source.aiExcluded)
            XCTAssertEqual(try service.loadStream(id: streamId)?.sources.first?.aiExcluded, true)

            source.aiExcluded = false
            try service.saveSource(source)
            XCTAssertEqual(try service.loadSource(id: sourceId)?.aiExcluded, false)
            XCTAssertEqual(try service.loadStream(id: streamId)?.sources.first?.aiExcluded, false)
        }
    }

    func test_chunkerUsesOutlineSectionPathsAndPageRanges() throws {
        let document = try makePDFDocument(pages: [
            "Opening receipts establish the first page.",
            "Storage receipts include the caliper phrase.",
            "Closing receipts finish the third page."
        ])
        try addOutline(to: document, labels: ["1 Opening", "2 Storage", "3 Closing"])

        let chunks = try ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            .chunkPDF(document: document, sourceId: UUID())

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.pageStart), [1, 2, 3])
        XCTAssertEqual(chunks.map(\.pageEnd), [1, 2, 3])
        XCTAssertEqual(chunks.map(\.sectionPath), ["1 Opening", "2 Storage", "3 Closing"])
        XCTAssertTrue(chunks[1].text.contains("caliper phrase"))
    }

    func test_sourceChunksAndFTSRowsAreRemovedWhenSourceIsDeleted() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let source = try savePDFSource(in: service)
            let chunk = SourceChunk(
                sourceId: source.id,
                seq: 0,
                text: "The ultraviolet caliper phrase should be found by FTS.",
                pageStart: 1,
                pageEnd: 1,
                sectionPath: "Fixtures"
            )

            try service.saveSourceChunks([chunk], for: source.id)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let matches = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT c.text
                        FROM source_chunks_fts
                        JOIN source_chunks c ON c.id = source_chunks_fts.chunk_id
                        WHERE source_chunks_fts MATCH ?
                    """,
                    arguments: ["ultraviolet"]
                ).map { row -> String in row["text"] }
            }

            XCTAssertEqual(matches, [chunk.text])

            try service.deleteSource(id: source.id)

            let counts = try dbQueue.read { db in
                let chunkCount: Int = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS count FROM source_chunks WHERE source_id = ?",
                    arguments: [source.id.uuidString]
                )?["count"] ?? -1
                let ftsCount: Int = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS count FROM source_chunks_fts WHERE source_id = ?",
                    arguments: [source.id.uuidString]
                )?["count"] ?? -1
                return (chunkCount, ftsCount)
            }

            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 0)
        }
    }

    func test_loadSourceChunkReturnsSingleChunkById() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let first = SourceChunk(
                sourceId: source.id,
                seq: 0,
                text: "First chunk text.",
                pageStart: 1,
                pageEnd: 1
            )
            let second = SourceChunk(
                sourceId: source.id,
                seq: 1,
                text: "Second chunk text.",
                pageStart: 2,
                pageEnd: 2
            )

            try service.saveSourceChunks([first, second], for: source.id)

            let loaded = try XCTUnwrap(service.loadSourceChunk(id: second.id))
            XCTAssertEqual(loaded.id, second.id)
            XCTAssertEqual(loaded.sourceId, second.sourceId)
            XCTAssertEqual(loaded.seq, second.seq)
            XCTAssertEqual(loaded.text, second.text)
            XCTAssertEqual(loaded.pageStart, second.pageStart)
            XCTAssertEqual(loaded.pageEnd, second.pageEnd)
            XCTAssertEqual(loaded.sectionPath, second.sectionPath)
            XCTAssertNil(try service.loadSourceChunk(id: UUID()))
        }
    }

    func test_retrievalReturnsNoContextForIrrelevantQuery() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Large Source")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed here.", 4, 4, "Storage")
                ]
            )

            let retrieval = RetrievalService(persistence: service)

            let unrelatedQuery = "what is the best way to do this"
            XCTAssertTrue(try retrieval.retrieve(query: unrelatedQuery, streamId: stream.id).isEmpty)
            XCTAssertNil(try retrieval.assembleSourceContext(query: unrelatedQuery, streamId: stream.id))
        }
    }

    func test_retrievalReturnsNoContextWhenAllQueryTokensMatchOnlyWeakly() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Weak Matches")
            try service.saveStream(stream)
            let weakChunks = weakUnrelatedChunks()
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Technical.pdf",
                extractedText: largeExtractedText(),
                chunks: weakChunks
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "good dish party friends"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let cutoff = -1.0 * Double(sanitized.tokenCount)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let corpusText = weakChunks.map(\.text).joined(separator: " ")

            XCTAssertEqual(sanitized.tokenCount, 4)
            XCTAssertTrue(["good", "dish", "party", "friends"].allSatisfy { corpusText.contains($0) })
            XCTAssertLessThan(bestScore, 0)
            XCTAssertGreaterThan(bestScore, cutoff)
            XCTAssertTrue(try retrieval.retrieve(query: query, streamId: stream.id).isEmpty)
            XCTAssertNil(try retrieval.assembleSourceContext(query: query, streamId: stream.id))
        }
    }

    func test_retrievalKeepsStrongMatchesAbovePerTokenCutoff() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Strong Match")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Interpreter.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "interpreter interpreter interpreter numeric numeric numeric conversion conversion conversion input input input",
                    pageStart: 9,
                    pageEnd: 9
                )
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "interpreter numeric conversion input"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let cutoff = -1.0 * Double(sanitized.tokenCount)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let results = try retrieval.retrieve(query: query, streamId: stream.id)

            XCTAssertEqual(sanitized.tokenCount, 4)
            XCTAssertLessThanOrEqual(bestScore, cutoff)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.sourceName, "Interpreter.pdf")
        }
    }

    func test_retrievalCapsPerTokenCutoffForLongParagraphQueries() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Long Query")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Interpreter.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "interpreter interpreter interpreter numeric numeric numeric",
                    pageStart: 10,
                    pageEnd: 10
                )
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "interpreter numeric conversion input handle source cursor paragraph manual chapter section reader"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let uncappedCutoff = -1.0 * Double(sanitized.tokenCount)
            let cappedCutoff = -1.0 * Double(8)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let results = try retrieval.retrieve(query: query, streamId: stream.id)

            XCTAssertEqual(sanitized.tokenCount, 12)
            XCTAssertGreaterThan(bestScore, uncappedCutoff)
            XCTAssertLessThanOrEqual(bestScore, cappedCutoff)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.sourceName, "Interpreter.pdf")
        }
    }

    func test_retrievalSourceScopeNoneReturnsNoContextEvenWithMatchingChunks() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scope None")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed here.", 4, 4, "Storage")
                ]
            )

            let context = try RetrievalService(persistence: service)
                .assembleSourceContext(query: "storage manifold", streamId: stream.id, scope: .none)

            XCTAssertNil(context)
        }
    }

    func test_retrievalSourceScopeAllReturnsWeakMatchesBelowAutoThreshold() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scope All")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Weak.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "weakterm " + String(repeating: "filler ", count: 30), 5, 5, nil),
                    (1, String(repeating: "other filler ", count: 10), 6, 6, nil)
                ]
            )

            let retrieval = RetrievalService(persistence: service)

            XCTAssertTrue(try retrieval.retrieve(query: "weakterm", streamId: stream.id).isEmpty)

            let context = try XCTUnwrap(
                retrieval.assembleSourceContext(query: "weakterm", streamId: stream.id, scope: .all)
            )
            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Weak.pdf"])
            XCTAssertTrue(context.text.contains("[1] Weak, p.5:"))
        }
    }

    func test_retrievalPassthroughUsesLegacyWholeTextFormatForSmallSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Small Sources")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "One.txt",
                extractedText: "First source text",
                indexStatus: .pending,
                addedAt: Date(timeIntervalSince1970: 1)
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Two.txt",
                extractedText: "Second source text",
                indexStatus: .ready,
                addedAt: Date(timeIntervalSince1970: 2)
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "anything", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .passthrough)
            XCTAssertEqual(context.text, "First source text\n\n---\n\nSecond source text")
        }
    }

    func test_retrievalPassthroughOmitsAIExcludedSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Private Small Sources")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.txt",
                extractedText: "Private source text",
                aiExcluded: true,
                addedAt: Date(timeIntervalSince1970: 1)
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Public.txt",
                extractedText: "Public source text",
                addedAt: Date(timeIntervalSince1970: 2)
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "anything", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .passthrough)
            XCTAssertEqual(context.text, "Public source text")
            XCTAssertFalse(context.text.contains("Private source text"))
        }
    }

    func test_retrievalReturnsNilContextWhenAllSourcesAreAIExcluded() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "All Private")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.txt",
                extractedText: "Private source text",
                aiExcluded: true
            )

            let context = try RetrievalService(persistence: service)
                .assembleSourceContext(query: "anything", streamId: stream.id)

            XCTAssertNil(context)
        }
    }

    func test_retrievalInterleavesMultipleSourcesByScore() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Multiple Sources")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Alpha.pdf",
                extractedText: largeExtractedText("alpha"),
                chunks: stronglyRelevantChunks(
                    strongText: "caliper caliper caliper storage storage storage manifold manifold manifold",
                    pageStart: 2,
                    pageEnd: 2
                )
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Beta.pdf",
                extractedText: largeExtractedText("beta"),
                chunks: stronglyRelevantChunks(
                    strongText: "caliper caliper storage storage manifold manifold",
                    pageStart: 8,
                    pageEnd: 8
                )
            )

            let results = try RetrievalService(persistence: service)
                .retrieve(query: "caliper storage manifold", streamId: stream.id)

            XCTAssertEqual(results.map(\.sourceName), ["Alpha.pdf", "Beta.pdf"])
            XCTAssertLessThanOrEqual(results[0].score, results[1].score)
        }
    }

    func test_retrievalChunksExcludeAIPrivateSourcesAndFillFromAllowedSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Private Retrieval")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.pdf",
                extractedText: largeExtractedText("private"),
                aiExcluded: true,
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold private private private",
                    pageStart: 3,
                    pageEnd: 3
                )
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Allowed.pdf",
                extractedText: largeExtractedText("allowed"),
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold allowed allowed allowed",
                    pageStart: 9,
                    pageEnd: 9
                )
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "storage manifold", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Allowed.pdf"])
            XCTAssertTrue(context.text.contains("allowed allowed allowed"))
            XCTAssertFalse(context.text.contains("private private private"))
        }
    }

    func test_retrievalSanitizesQuerySyntaxWithoutThrowing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Sanitize")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Syntax.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Quotes and parens appear in this chunk.", 1, 1, nil)
                ]
            )

            XCTAssertNoThrow(
                try RetrievalService(persistence: service)
                    .retrieve(query: #""quotes" AND (parens) don't-crash"#, streamId: stream.id)
            )
        }
    }

    func test_retrievalManifestIncludesNumbersSourcePagesAndSection() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Manifest")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold receipts receipts receipts",
                    pageStart: 12,
                    pageEnd: 14,
                    sectionPath: "3.2 Storage"
                )
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "storage manifold receipts", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.text, """
            [1] Manual, p.12–14 (§3.2 Storage):
            storage storage storage manifold manifold manifold receipts receipts receipts
            """)
        }
    }

    func test_ingestServiceIndexesPDFAndEmitsStatusTransitions() throws {
        try withTempPersistenceServiceAndURL { service, _, fileManager in
            let stream = Stream(title: "Ingest Ready")
            try service.saveStream(stream)

            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { _ = try? fileManager.removeItem(at: tempDir) }

            let pdfURL = tempDir.appendingPathComponent("Ready.pdf")
            try makePDFData(pages: ["Ready receipt text with the anvil phrase."]).write(to: pdfURL)

            let sourceService = SourceService(persistence: service)
            let source = try sourceService.addSource(from: pdfURL, to: stream.id)
            let ingestService = IngestService(
                persistence: service,
                sourceService: sourceService,
                chunkingService: ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            )

            let ready = expectation(description: "source indexed")
            let lock = NSLock()
            var statuses: [SourceIndexStatus] = []
            ingestService.onStatusChange = { update in
                lock.lock()
                statuses.append(update.status)
                lock.unlock()
                if update.status == .ready {
                    ready.fulfill()
                }
            }

            ingestService.enqueue(source: source)
            wait(for: [ready], timeout: 5)

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(reloaded.indexStatus, .ready)
            XCTAssertFalse(try service.loadSourceChunks(sourceId: source.id).isEmpty)
            lock.lock()
            let capturedStatuses = statuses
            lock.unlock()
            XCTAssertTrue(capturedStatuses.contains(.indexing))
            XCTAssertTrue(capturedStatuses.contains(.ready))
        }
    }

    func test_ingestServiceMarksNoTextPDFAsFailedNoText() throws {
        try withTempPersistenceServiceAndURL { service, _, fileManager in
            let stream = Stream(title: "Ingest No Text")
            try service.saveStream(stream)

            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { _ = try? fileManager.removeItem(at: tempDir) }

            let pdfURL = tempDir.appendingPathComponent("Blank.pdf")
            try makePDFData(pages: [""]).write(to: pdfURL)

            let sourceService = SourceService(persistence: service)
            let source = try sourceService.addSource(from: pdfURL, to: stream.id)
            let ingestService = IngestService(
                persistence: service,
                sourceService: sourceService,
                chunkingService: ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            )

            let failed = expectation(description: "source failed without text")
            ingestService.onStatusChange = { update in
                if update.status == .failedNoText {
                    failed.fulfill()
                }
            }

            ingestService.enqueue(source: source)
            wait(for: [failed], timeout: 5)

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(reloaded.indexStatus, .failedNoText)
            XCTAssertTrue(try service.loadSourceChunks(sourceId: source.id).isEmpty)
        }
    }

    func test_savePDFHighlightRoundTripsRects() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 2,
                rects: [
                    PDFHighlightRect(page: 2, x: 10.5, y: 20.25, w: 120, h: 14),
                    PDFHighlightRect(page: 3, x: 11, y: 30, w: 98.75, h: 16.5),
                ],
                quote: "Important quoted text",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [highlight])
        }
    }

    func test_sourceAccessRecoversCorruptedBookmarkFromOriginalPath() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("Recovered.pdf")
        try Data("%PDF-1.4\n%EOF\n".utf8).write(to: fileURL)
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        try withTempPersistenceService { service in
            let stream = Stream(title: "Bookmark Recovery")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Recovered.pdf",
                fileType: .pdf,
                bookmarkData: Data("not-a-bookmark".utf8),
                originalPath: fileURL.path,
                status: .stale,
                extractedText: "cached text"
            )
            try service.saveSource(source)

            let sourceService = SourceService(persistence: service)
            let recoveredURL = try sourceService.accessFile(source)
            defer { recoveredURL.stopAccessingSecurityScopedResource() }

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(recoveredURL.path, fileURL.path)
            XCTAssertEqual(reloaded.originalPath, fileURL.path)
            XCTAssertNotEqual(reloaded.bookmarkData, source.bookmarkData)
            XCTAssertEqual(reloaded.status, .ready)
        }
    }

    func test_savePDFPointAnchorRoundTripsEmptyQuoteAndMarkerRect() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let anchor = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 4,
                rects: [PDFHighlightRect(page: 4, x: 42, y: 84, w: 14, h: 14)],
                quote: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )

            try service.savePDFHighlight(anchor)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [anchor])
        }
    }

    func test_deleteSourceDeletesPDFHighlights() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "Remove me",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)
            try service.deleteSource(id: source.id)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [])
        }
    }

    func test_deletePDFHighlightsKeepsReferencedRowsAndDeletesUnreferencedRows() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let referenced = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 2,
                rects: [PDFHighlightRect(page: 2, x: 10, y: 20, w: 30, h: 12)],
                quote: "Keep this",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let unreferenced = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 4,
                rects: [PDFHighlightRect(page: 4, x: 42, y: 84, w: 14, h: 14)],
                quote: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )

            try service.savePDFHighlight(referenced)
            try service.savePDFHighlight(unreferenced)

            let deletedIds = try service.deletePDFHighlights(
                sourceIds: [source.id],
                excludingIds: [referenced.id.uuidString.lowercased()]
            )

            XCTAssertEqual(deletedIds, [unreferenced.id.uuidString])
            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [referenced])
        }
    }

    func test_deletePDFHighlightsIsScopedToSavedStreamSources() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let otherStreamSource = try savePDFSource(in: service)
            let sourceHighlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "Remove only this stream",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let otherStreamHighlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: otherStreamSource.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 5, y: 6, w: 7, h: 8)],
                quote: "Must survive",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )

            try service.savePDFHighlight(sourceHighlight)
            try service.savePDFHighlight(otherStreamHighlight)

            let deletedIds = try service.deletePDFHighlights(sourceIds: [source.id], excludingIds: [])

            XCTAssertEqual(deletedIds, [sourceHighlight.id.uuidString])
            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [])
            XCTAssertEqual(try service.loadPDFHighlights(sourceId: otherStreamSource.id), [otherStreamHighlight])
        }
    }

    func test_pdfHighlightLinkReferenceExtractorFindsValidTickerPDFHighlightIds() throws {
        let sourceId = UUID()
        let firstHighlightId = UUID()
        let secondHighlightId = UUID()
        let markdown = """
        Intro [quoted text](ticker-pdf://\(sourceId.uuidString)?highlight=\(firstHighlightId.uuidString)&page=4)

        Another saved link: <ticker-pdf://\(sourceId.uuidString)?page=7&HIGHLIGHT=\(secondHighlightId.uuidString.lowercased())>

        Ignore malformed links:
        [bad](ticker-pdf://\(sourceId.uuidString)?highlight=76C2D82A-not-a-uuid&page=3)
        [external](https://example.com?highlight=\(UUID().uuidString))
        """

        let ids = PDFHighlightLinkReferenceExtractor.highlightIds(in: markdown)

        XCTAssertEqual(ids, Set([firstHighlightId.uuidString, secondHighlightId.uuidString]))
    }

    func test_tickerPDFURLParserAcceptsExistingHighlightDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let highlightId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?highlight=\(highlightId.uuidString)&page=4")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertEqual(destination.highlightId, highlightId.uuidString)
        XCTAssertEqual(destination.page, 4)
        XCTAssertNil(destination.chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_tickerPDFURLParserAcceptsLegacyBareHighlightDestination() throws {
        let highlightId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(highlightId.uuidString)")
        )

        XCTAssertNil(destination.sourceId)
        XCTAssertEqual(destination.highlightId, highlightId.uuidString)
        XCTAssertNil(destination.page)
        XCTAssertNil(destination.chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_tickerPDFURLParserAcceptsCitationChunkDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?page=12&chunk=\(chunkId.uuidString)")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertNil(destination.highlightId)
        XCTAssertEqual(destination.page, 12)
        XCTAssertEqual(destination.chunkId, chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_tickerPDFURLParserAcceptsCitationQuoteDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?page=12&chunk=\(chunkId.uuidString)&q=quoted%20evidence%20%26%20support")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertNil(destination.highlightId)
        XCTAssertEqual(destination.page, 12)
        XCTAssertEqual(destination.chunkId, chunkId)
        XCTAssertEqual(destination.quote, "quoted evidence & support")
    }

    func test_openPDFDestinationFailureMessagesArePlainLanguage() throws {
        XCTAssertEqual(
            OpenPDFDestinationFailure.missingSource.userMessage,
            "This link points to a source that's no longer in this stream."
        )
        XCTAssertEqual(
            OpenPDFDestinationFailure.damagedLink.userMessage,
            "This link is damaged and can't be opened."
        )
        XCTAssertEqual(
            OpenPDFDestinationFailure.wrongStream.userMessage,
            "This link points to a source in another stream."
        )
    }

    func test_pdfPaneOpeningLayoutExpandsToVisibleFrameWidthAndSplitsEvenly() throws {
        let layout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 220, y: 120, width: 900, height: 700),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875),
            isNativeFullscreen: false
        )

        XCTAssertEqual(layout.targetWindowFrame, CGRect(x: 0, y: 120, width: 1440, height: 700))
        XCTAssertEqual(layout.paneWidth, 720)
        XCTAssertTrue(layout.shouldResizeWindow)
    }

    func test_pdfPaneOpeningLayoutClampsHeightAndVerticalPositionInsideVisibleFrame() throws {
        let layout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 220, y: -200, width: 900, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
            isNativeFullscreen: false
        )

        XCTAssertEqual(layout.targetWindowFrame, CGRect(x: 0, y: 25, width: 1440, height: 800))
        XCTAssertEqual(layout.paneWidth, 720)
        XCTAssertTrue(layout.shouldResizeWindow)
    }

    func test_pdfPaneOpeningLayoutSkipsResizeForFullWidthOrFullscreenWindow() throws {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let fullWidthLayout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: -10, y: 120, width: 1500, height: 700),
            visibleFrame: visibleFrame,
            isNativeFullscreen: false
        )
        let fullscreenLayout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 220, y: 120, width: 900, height: 700),
            visibleFrame: visibleFrame,
            isNativeFullscreen: true
        )

        XCTAssertEqual(fullWidthLayout.targetWindowFrame, CGRect(x: -10, y: 120, width: 1500, height: 700))
        XCTAssertEqual(fullWidthLayout.paneWidth, 750)
        XCTAssertFalse(fullWidthLayout.shouldResizeWindow)
        XCTAssertEqual(fullscreenLayout.targetWindowFrame, CGRect(x: 220, y: 120, width: 900, height: 700))
        XCTAssertEqual(fullscreenLayout.paneWidth, 450)
        XCTAssertFalse(fullscreenLayout.shouldResizeWindow)
    }

    func test_pdfPaneWindowRestoreUsesSavedFrameExceptInFullscreen() throws {
        let saved = CGRect(x: 120, y: 80, width: 900, height: 700)

        XCTAssertEqual(PDFPaneWindowRestore.targetFrame(savedFrame: saved, isNativeFullscreen: false), saved)
        XCTAssertNil(PDFPaneWindowRestore.targetFrame(savedFrame: saved, isNativeFullscreen: true))
        XCTAssertNil(PDFPaneWindowRestore.targetFrame(savedFrame: nil, isNativeFullscreen: false))
    }

    func test_pdfFindNavigationWrapsNextAndPrevious() throws {
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: nil, matchCount: 3), 0)
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: 0, matchCount: 3), 1)
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: 2, matchCount: 3), 0)

        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: nil, matchCount: 3), 2)
        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: 2, matchCount: 3), 1)
        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: 0, matchCount: 3), 2)

        XCTAssertNil(PDFFindNavigation.nextIndex(currentIndex: nil, matchCount: 0))
        XCTAssertNil(PDFFindNavigation.previousIndex(currentIndex: nil, matchCount: 0))
    }

    func test_pdfDocumentFindReturnsCaseInsensitiveOrderedSelections() throws {
        let document = try makePDFDocument(pages: [
            "First needle is on the opening page.",
            "Second page carries NEEDLE again.",
            "No match here."
        ])

        let results = PDFDocumentFind.matches(in: document, query: "needle")

        XCTAssertFalse(results.isCapped)
        XCTAssertEqual(results.selections.count, 2)
        XCTAssertEqual(results.selections.compactMap { $0.pages.first.map { document.index(for: $0) } }, [0, 1])
        XCTAssertEqual(
            results.selections.compactMap { $0.string?.lowercased() },
            ["needle", "needle"]
        )
    }

    func test_pdfCitationNavigatorNormalizesQuoteText() throws {
        XCTAssertEqual(
            PDFCitationNavigator.normalizeQuote("Reader\u{2019}s \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines"),
            "reader's \"quoted\" text across lines"
        )
    }

    func test_pdfCitationNavigatorRecoversOriginalChunkSpanFromNormalizedQuote() throws {
        let chunkText = "Before reader's \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines after."
        let span = PDFCitationNavigator.verifiedOriginalSpan(
            in: chunkText,
            quote: "reader\u{2019}s \"quoted\"   text across lines"
        )

        XCTAssertEqual(span, "reader's \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines")
    }

    func test_pdfCitationNavigatorUsesFirstGenericPhraseInChunk() throws {
        let chunkText = "First CHECK for stack underflow here. Later check for stack underflow there."
        let span = PDFCitationNavigator.verifiedOriginalSpan(
            in: chunkText,
            quote: "check for stack underflow"
        )

        XCTAssertEqual(span, "CHECK for stack underflow")
    }

    func test_pdfCitationNavigatorReturnsNilWhenQuoteIsAbsentFromChunk() throws {
        XCTAssertNil(
            PDFCitationNavigator.verifiedOriginalSpan(
                in: "Chunk text contains unrelated evidence.",
                quote: "absent quoted evidence"
            )
        )
    }

    func test_pdfCitationFallbackAffordanceOnlyShowsForCitationChunkFallback() throws {
        XCTAssertTrue(PDFCitationFallbackAffordance.shouldShow(chunkPresent: true, matchFound: false))
        XCTAssertFalse(PDFCitationFallbackAffordance.shouldShow(chunkPresent: true, matchFound: true))
        XCTAssertFalse(PDFCitationFallbackAffordance.shouldShow(chunkPresent: false, matchFound: false))
    }

    func test_pdfCitationNavigatorSelectsVerifiedQuoteOnExtractedPage() throws {
        let document = try makePDFDocument(pages: [
            "First page has only setup text.",
            "Second page says stack cells remain available for verified citation flashes.",
            "Third page has unrelated text."
        ])
        let chunkText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: chunkText,
            pageStart: 1,
            pageEnd: 3
        )

        let quote = "stack cells remain available for verified citation flashes"
        let match = try XCTUnwrap(PDFCitationNavigator.match(in: document, chunk: chunk, quote: quote))

        XCTAssertEqual(document.index(for: match.page), 1)
        XCTAssertFalse(match.bounds.isEmpty)
        XCTAssertTrue(PDFCitationNavigator.normalizeQuote(match.selection.string ?? "").contains(quote))
    }

    func test_pdfCitationNavigatorReturnsNilWhenVerifiedSpanIsAbsentFromPageText() throws {
        let document = try makePDFDocument(pages: [
            "First page text.",
            "Second page text."
        ])
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: "The stored chunk has absent quoted evidence that the page text does not expose.",
            pageStart: 2,
            pageEnd: 2
        )

        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: "absent quoted evidence"))
    }

    func test_pdfCitationNavigatorFallsBackToPageWhenQuoteIsAbsentOrMissed() throws {
        let document = try makePDFDocument(pages: [
            "First page text.",
            "Second page text."
        ])
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: "This absent sentence is long enough to become the citation search needle.",
            pageStart: 2,
            pageEnd: 2
        )

        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: nil))
        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: "absent quoted evidence"))
        XCTAssertEqual(PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: nil), 2)
        XCTAssertEqual(PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: 1), 1)
    }

    func test_sourceShortTitleUsesAnnaArchiveFirstFilenameSegment() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "Thinking Forth -- Leo Brodie -- Anna's Archive.pdf"
            ),
            "Thinking Forth"
        )
    }

    func test_sourceShortTitleUsesPlainFilenameStem() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(displayName: "report.pdf"),
            "report"
        )
    }

    func test_sourceShortTitlePrefersSaneMetadataTitle() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "123456789.pdf",
                metadataTitle: "Clean Metadata Title"
            ),
            "Clean Metadata Title"
        )
    }

    func test_documentAICitationPayloadBuildsFromRetrievedSourceContext() throws {
        let firstSourceId = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let secondSourceId = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let firstChunkId = try XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let secondChunkId = try XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let context = SourceContext(
            text: "[1] abcdefghijklmnopqrstuvwxyzABCDE.pdf, p.12:\nAlpha\n\n[2] Guide.md, p.2:\nBeta",
            chunks: [
                RetrievedChunk(
                    id: firstChunkId,
                    sourceId: firstSourceId,
                    sourceName: "abcdefghijklmnopqrstuvwxyzABCDE.pdf",
                    seq: 0,
                    text: "Alpha",
                    pageStart: 12,
                    pageEnd: 12,
                    sectionPath: nil,
                    score: -10
                ),
                RetrievedChunk(
                    id: secondChunkId,
                    sourceId: secondSourceId,
                    sourceName: "Guide.md",
                    seq: 1,
                    text: "Beta",
                    pageStart: 2,
                    pageEnd: 3,
                    sectionPath: nil,
                    score: -8
                )
            ],
            mode: .retrieved
        )

        let payload = try XCTUnwrap(DocumentAICitationManifest.bridgePayload(from: context))

        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0]["n"] as? Int, 1)
        XCTAssertEqual(payload[0]["chunkId"] as? String, firstChunkId.uuidString)
        XCTAssertEqual(payload[0]["sourceId"] as? String, firstSourceId.uuidString)
        XCTAssertEqual(payload[0]["page"] as? Int, 12)
        XCTAssertEqual(payload[0]["shortTitle"] as? String, "abcdefghijk...vwxyzABCDE")
        XCTAssertEqual(payload[1]["n"] as? Int, 2)
        XCTAssertEqual(payload[1]["chunkId"] as? String, secondChunkId.uuidString)
        XCTAssertEqual(payload[1]["sourceId"] as? String, secondSourceId.uuidString)
        XCTAssertEqual(payload[1]["page"] as? Int, 2)
        XCTAssertEqual(payload[1]["shortTitle"] as? String, "Guide")
    }

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

    func test_saveStreamDocumentWithCurrentRevisionIncrementsRevision() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Revision Save")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(initialDocument.revision, 0)

            let firstRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "First save",
                baseRevision: initialDocument.revision
            )
            XCTAssertEqual(firstRevision, 1)

            let firstDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(firstDocument.markdown, "First save")
            XCTAssertEqual(firstDocument.revision, 1)

            let secondRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Second save",
                baseRevision: firstDocument.revision
            )
            XCTAssertEqual(secondRevision, 2)

            let secondDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(secondDocument.markdown, "Second save")
            XCTAssertEqual(secondDocument.revision, 2)
        }
    }

    func test_appendToStreamDocumentIncrementsRevision() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Append Revision")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(initialDocument.revision, 0)

            let firstAppend = try service.appendToStreamDocument(streamId: stream.id, fragment: "First append")
            XCTAssertEqual(firstAppend.revision, 1)

            let secondAppend = try service.appendToStreamDocument(streamId: stream.id, fragment: "Second append")
            XCTAssertEqual(secondAppend.revision, 2)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "First append\n\nSecond append")
            XCTAssertEqual(document.revision, 2)
        }
    }

    func test_staleRevisionSaveDoesNotClobberInterleavedAppend() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Conflict Guard")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let savedRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Editor draft",
                baseRevision: initialDocument.revision
            )
            XCTAssertEqual(savedRevision, 1)

            let append = try service.appendToStreamDocument(streamId: stream.id, fragment: "External append")
            XCTAssertEqual(append.revision, 2)

            do {
                _ = try service.saveStreamDocument(
                    streamId: stream.id,
                    markdown: "Editor stale overwrite",
                    baseRevision: savedRevision
                )
                XCTFail("Expected stale revision save to throw")
            } catch let conflict as StreamDocumentRevisionConflict {
                XCTAssertEqual(conflict.streamId, stream.id)
                XCTAssertEqual(conflict.revision, append.revision)
                XCTAssertEqual(conflict.markdown, "Editor draft\n\nExternal append")
            }

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Editor draft\n\nExternal append")
            XCTAssertEqual(document.revision, append.revision)
        }
    }

    func test_loadStreamSummariesUsesDocumentMarkdownAndUpdatedAtOrdering() throws {
        try withTempPersistenceService { service in
            let olderStream = Stream(title: "Older Stream")
            let newerStream = Stream(title: "Newer Stream")
            try service.saveStream(olderStream)
            try service.saveStream(newerStream)

            let olderMarkdown = "# Older Notes\n\nThe older document preview comes from markdown."
            let newerMarkdown = """
            Newer document preview

            ![diagram](ticker-asset://stream/diagram.png)
            ![photo](https://example.com/photo.jpg)

            Second paragraph.
            """
            _ = try service.saveStreamDocument(
                streamId: olderStream.id,
                markdown: olderMarkdown
            )
            Thread.sleep(forTimeInterval: 0.01)
            _ = try service.saveStreamDocument(
                streamId: newerStream.id,
                markdown: newerMarkdown
            )

            let summaries = try service.loadStreamSummaries()

            XCTAssertEqual(summaries.map(\.id), [newerStream.id, olderStream.id])
            XCTAssertGreaterThan(
                try XCTUnwrap(summaries.first?.updatedAt.timeIntervalSince1970),
                try XCTUnwrap(summaries.dropFirst().first?.updatedAt.timeIntervalSince1970)
            )

            let newerSummary = try XCTUnwrap(summaries.first { $0.id == newerStream.id })
            XCTAssertEqual(newerSummary.previewText, newerMarkdown)
            XCTAssertEqual(newerSummary.charCount, newerMarkdown.count)
            XCTAssertEqual(newerSummary.imageCount, 2)

            let olderSummary = try XCTUnwrap(summaries.first { $0.id == olderStream.id })
            XCTAssertEqual(olderSummary.previewText, olderMarkdown)
            XCTAssertEqual(olderSummary.charCount, olderMarkdown.count)
            XCTAssertEqual(olderSummary.imageCount, 0)
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

            let retrievalService = RetrievalService(persistence: service)
            let searchService = SearchService(
                persistence: service,
                retrieval: retrievalService
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

    func test_hybridSearchStillFindsAIExcludedSourceChunksLocally() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Local Private Search")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.pdf",
                extractedText: largeExtractedText("private"),
                aiExcluded: true,
                chunks: stronglyRelevantChunks(
                    strongText: "privatephrase privatephrase privatephrase local local local",
                    pageStart: 7,
                    pageEnd: 7
                )
            )

            let searchService = SearchService(
                persistence: service,
                retrieval: RetrievalService(persistence: service)
            )

            let results = try await searchService.hybridSearch(
                query: "privatephrase",
                currentStreamId: stream.id,
                limit: 5
            )

            let chunkResult = try XCTUnwrap(
                results.currentStreamResults.first { $0.sourceType.rawValue == "chunk" }
            )
            XCTAssertEqual(chunkResult.sourceName, "Private.pdf")
            XCTAssertTrue(chunkResult.snippet.contains("privatephrase"))
        }
    }

    func test_migrationBackupIsCreatedWhenExistingDatabaseHasPendingMigrations() throws {
        try withSeededV10Database { _ in
            // v10 is intentionally behind the service's registered migrations.
        } body: { dbURL, fileManager in
            _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            XCTAssertEqual(
                try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).count,
                1
            )
        }
    }

    func test_migrationBackupIsNotCreatedWhenExistingDatabaseHasNoPendingMigrations() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        XCTAssertEqual(
            try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).count,
            0
        )
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

    func test_v12MigrationDoesNotTouchStreamsWithExistingDocumentRow() throws {
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

    func test_v12MigrationSeedsDocumentForCellOnlyStream() throws {
        let streamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Cell-only Stream", createdAt: 900)
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Second legacy note</p>",
                createdAt: 1_002,
                position: 1
            )
            try insertCell(
                db,
                streamId: streamId,
                content: #"<p><img src="ticker-asset:///stream/capture.png" alt="Screenshot"></p>"#,
                createdAt: 1_003,
                position: 1
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>First legacy note</p>",
                createdAt: 1_001,
                position: 0
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertEqual(document.markdown, """
            First legacy note

            Second legacy note

            ![capture](ticker-asset:///stream/capture.png)
            """)
        }
    }

    func test_v12MigrationDoesNotCreateDocumentForStreamWithoutCells() throws {
        let streamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Empty Legacy Stream", createdAt: 900)
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            XCTAssertNil(try service.loadStreamDocument(streamId: streamId))

            let document = try service.loadOrCreateStreamDocument(streamId: streamId)
            XCTAssertEqual(document.markdown, "")
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

    private func withTempPersistenceServiceAndURL(
        _ body: (PersistenceService, URL, FileManager) throws -> Void
    ) throws {
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

        try body(service, dbURL, fileManager)
    }

    private func savePDFSource(in service: PersistenceService) throws -> SourceReference {
        let stream = Stream(title: "PDF Highlights")
        try service.saveStream(stream)

        let source = SourceReference(
            streamId: stream.id,
            displayName: "Document.pdf",
            fileType: .pdf,
            bookmarkData: Data("bookmark".utf8),
            status: .ready
        )
        try service.saveSource(source)
        return source
    }

    private func saveRetrievalSource(
        in service: PersistenceService,
        streamId: UUID,
        displayName: String,
        extractedText: String,
        indexStatus: SourceIndexStatus = .ready,
        aiExcluded: Bool = false,
        addedAt: Date = Date(),
        chunks chunkFixtures: [RetrievalChunkFixture] = []
    ) throws -> SourceReference {
        let source = SourceReference(
            streamId: streamId,
            displayName: displayName,
            fileType: .pdf,
            bookmarkData: Data("bookmark-\(displayName)".utf8),
            status: .ready,
            extractedText: extractedText,
            pageCount: 20,
            indexStatus: indexStatus,
            aiExcluded: aiExcluded,
            addedAt: addedAt
        )
        try service.saveSource(source)

        let chunks = chunkFixtures.map { fixture in
            SourceChunk(
                sourceId: source.id,
                seq: fixture.seq,
                text: fixture.text,
                pageStart: fixture.pageStart,
                pageEnd: fixture.pageEnd,
                sectionPath: fixture.sectionPath
            )
        }
        try service.saveSourceChunks(chunks, for: source.id)
        return source
    }

    private func largeExtractedText(_ marker: String = "large") -> String {
        String(repeating: "\(marker) source context. ", count: 2_500)
    }

    private func stronglyRelevantChunks(
        strongText: String,
        pageStart: Int,
        pageEnd: Int,
        sectionPath: String? = nil
    ) -> [RetrievalChunkFixture] {
        genericRetrievalFillerChunks(count: 40, startingSeq: 1)
            + [(0, strongText, pageStart, pageEnd, sectionPath)]
    }

    private func weakUnrelatedChunks() -> [RetrievalChunkFixture] {
        var chunks = genericRetrievalFillerChunks(count: 40, startingSeq: 0)
        var seq = chunks.count
        for token in ["good", "dish", "party", "friends"] {
            for index in 0..<10 {
                chunks.append((
                    seq,
                    "\(token) compiler pipeline register cache \(index)",
                    seq + 1,
                    seq + 1,
                    nil
                ))
                seq += 1
            }
        }
        return chunks
    }

    private func genericRetrievalFillerChunks(count: Int, startingSeq: Int) -> [RetrievalChunkFixture] {
        (0..<count).map { offset in
            let seq = startingSeq + offset
            return (
                seq,
                "technical parser runtime buffer queue memory index compiler register module \(seq)",
                seq + 1,
                seq + 1,
                nil
            )
        }
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

    private func withSeededV15Database(
        seed: (Database) throws -> Void,
        body: (URL, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var dbQueue: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try dbQueue?.write { db in
            try createV15Schema(db)
            try seed(db)
            try markV15MigrationsApplied(db)
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
            CREATE TABLE sources (
                id TEXT PRIMARY KEY,
                stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                file_type TEXT NOT NULL,
                bookmark_data BLOB NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                extracted_text TEXT,
                page_count INTEGER,
                added_at DOUBLE NOT NULL,
                embedding_status TEXT DEFAULT 'none'
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_sources_stream ON sources(stream_id)")
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

    private func createV15Schema(_ db: Database) throws {
        try createV10Schema(db)

        try db.execute(sql: """
            CREATE TABLE source_chunks (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                token_count INTEGER NOT NULL,
                page_start INTEGER,
                page_end INTEGER,
                embedding_status TEXT NOT NULL DEFAULT 'pending',
                created_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_chunks_source ON source_chunks(source_id)")
        try db.execute(sql: "CREATE INDEX idx_chunks_status ON source_chunks(embedding_status)")
        try db.execute(sql: """
            CREATE TABLE chunk_embeddings (
                chunk_id TEXT PRIMARY KEY REFERENCES source_chunks(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL,
                model TEXT NOT NULL,
                created_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "ALTER TABLE stream_documents ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: """
            CREATE TABLE pdf_highlights (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                page INTEGER NOT NULL,
                rects_json TEXT NOT NULL,
                quote TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_pdf_highlights_source ON pdf_highlights(source_id)")
        try db.execute(sql: "ALTER TABLE sources ADD COLUMN original_path TEXT")
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

    private func markV15MigrationsApplied(_ db: Database) throws {
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
            "v10_stream_documents",
            "v11_recover_orphaned_quickpanel_cells",
            "v12_seed_documents_from_legacy_cells",
            "v13_stream_document_revision",
            "v14_pdf_highlights",
            "v15_source_original_path"
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

    private func insertV15Source(
        _ db: Database,
        id: UUID,
        streamId: UUID,
        displayName: String,
        fileType: String,
        pageCount: Int?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sources (
                    id,
                    stream_id,
                    display_name,
                    file_type,
                    bookmark_data,
                    status,
                    extracted_text,
                    page_count,
                    added_at,
                    embedding_status,
                    original_path
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id.uuidString,
                streamId.uuidString,
                displayName,
                fileType,
                Data("bookmark".utf8),
                "ready",
                "legacy extracted text",
                pageCount,
                1_000,
                "none",
                nil
            ]
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
        XCTAssertTrue(
            try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).isEmpty == false,
            "Expected pre-migration backup for existing DB with pending v11 migration"
        )
    }

    private func preMigrationBackups(nextTo dbURL: URL, fileManager: FileManager) throws -> [URL] {
        let backupsDirectory = dbURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        guard fileManager.fileExists(atPath: backupsDirectory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "db" }
    }

    private func makePDFDocument(pages: [String]) throws -> PDFDocument {
        let data = try makePDFData(pages: pages)
        guard let document = PDFDocument(data: data) else {
            throw TestPDFError.creationFailed
        }
        return document
    }

    private func makePDFData(pages: [String]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw TestPDFError.creationFailed
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestPDFError.creationFailed
        }

        for text in pages {
            context.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext

            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.black
                ]
            )
            attributed.draw(in: CGRect(x: 72, y: 650, width: 468, height: 80))

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    private func addOutline(to document: PDFDocument, labels: [String]) throws {
        let root = PDFOutline()
        for (index, label) in labels.enumerated() {
            guard let page = document.page(at: index) else {
                throw TestPDFError.creationFailed
            }
            let outline = PDFOutline()
            outline.label = label
            outline.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 0))
            root.insertChild(outline, at: root.numberOfChildren)
        }
        document.outlineRoot = root
    }
}
