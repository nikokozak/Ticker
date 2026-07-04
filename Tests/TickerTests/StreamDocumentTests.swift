import CoreGraphics
import Foundation
import GRDB
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
}

final class StreamDocumentTests: XCTestCase {
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
}
