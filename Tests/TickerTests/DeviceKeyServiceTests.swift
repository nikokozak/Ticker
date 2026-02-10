import XCTest

@testable import Ticker

final class DeviceKeyServiceTests: XCTestCase {
    func test_loadProxyAuth_createsDeviceJsonWithPrivatePermissions() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("device.json")
        let service = DeviceKeyService(fileURL: fileURL)

        _ = await service.loadProxyAuth()

        XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))

        let dirAttrs = try fileManager.attributesOfItem(atPath: tempDir.path)
        let dirPerms = dirAttrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirPerms?.intValue, 0o700)

        let fileAttrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let filePerms = fileAttrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePerms?.intValue, 0o600)
    }

    func test_loadProxyAuth_cleansUpStaleTempFiles() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("device.json")

        let legacyTempURL = fileURL.appendingPathExtension("tmp")
        try "legacy".data(using: .utf8)?.write(to: legacyTempURL)

        let newTempURL = tempDir.appendingPathComponent("device.json.tmp.\(UUID().uuidString)")
        try "new".data(using: .utf8)?.write(to: newTempURL)

        XCTAssertTrue(fileManager.fileExists(atPath: legacyTempURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newTempURL.path))

        let service = DeviceKeyService(fileURL: fileURL)
        _ = await service.loadProxyAuth()

        XCTAssertFalse(fileManager.fileExists(atPath: legacyTempURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: newTempURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
    }

    func test_getSupportBundle_neverIncludesDeviceKey() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("device.json")

        var device = DeviceKeyData(deviceId: UUID().uuidString, deviceKey: "tk_live_test_key")
        device.supportId = "sup_test"
        device.validatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(device)
        try encoded.write(to: fileURL)

        let service = DeviceKeyService(fileURL: fileURL)
        _ = await service.loadProxyAuth()

        let bundle = await service.getSupportBundle()
        XCTAssertNil(bundle["device_key"])

        let bundleData = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let bundleString = String(data: bundleData, encoding: .utf8)
        XCTAssertFalse(bundleString?.contains("tk_live_test_key") ?? false)
    }

    func test_recordRequestId_capsAt50() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("device.json")
        let service = DeviceKeyService(fileURL: fileURL)

        _ = await service.loadProxyAuth()

        for i in 0..<60 {
            await service.recordRequestId("req-\(i)", endpoint: "llm")
        }

        let bundle = await service.getSupportBundle()
        guard let recent = bundle["recent_request_ids"] as? [[String: Any]] else {
            XCTFail("Expected recent_request_ids array")
            return
        }

        XCTAssertEqual(recent.count, 50)
        XCTAssertEqual(recent.first?["request_id"] as? String, "req-10")
        XCTAssertEqual(recent.last?["request_id"] as? String, "req-59")
    }
}

final class PersistenceServiceQuickPanelTests: XCTestCase {
    func test_insertQuickPanelCells_insertsAdjacentPairBeforeTrailingEmptyCell() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Test Stream")
            try service.saveStream(stream)

            let leading = Cell(
                streamId: stream.id,
                content: "<p>Existing note</p>",
                type: .text,
                order: 0
            )
            let trailingEmpty = Cell(
                streamId: stream.id,
                content: "<p></p>",
                type: .text,
                order: 1
            )

            try service.saveCell(leading)
            try service.saveCell(trailingEmpty)

            let context = Cell(
                streamId: stream.id,
                content: "<p><img src=\"ticker-asset:///stream/s1.png\" alt=\"Screenshot\"></p>",
                type: .quote,
                order: 0
            )
            let note = Cell(
                streamId: stream.id,
                content: "<p>A quick note</p>",
                type: .text,
                order: 0
            )

            let inserted = try service.insertQuickPanelCells(streamId: stream.id, cells: [context, note])
            XCTAssertEqual(inserted.count, 2)
            XCTAssertEqual(inserted[0].order, 1)
            XCTAssertEqual(inserted[1].order, 2)

            guard let loaded = try service.loadStream(id: stream.id) else {
                XCTFail("Expected stream to load")
                return
            }

            let sorted = loaded.cells.sorted { $0.order < $1.order }
            XCTAssertEqual(sorted.map(\.id), [leading.id, context.id, note.id, trailingEmpty.id])
            XCTAssertEqual(sorted.map(\.order), [0, 1, 2, 3])
        }
    }

    func test_insertQuickPanelCells_repeatedCapturesKeepEachPairAdjacent() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Repeated Captures")
            try service.saveStream(stream)

            let base = Cell(
                streamId: stream.id,
                content: "<p>Start</p>",
                type: .text,
                order: 0
            )
            let trailingEmpty = Cell(
                streamId: stream.id,
                content: "<p></p>",
                type: .text,
                order: 1
            )
            try service.saveCell(base)
            try service.saveCell(trailingEmpty)

            var capturePairs: [(quoteId: UUID, noteId: UUID)] = []

            for idx in 0..<3 {
                let quote = Cell(
                    streamId: stream.id,
                    content: "<p><img src=\"ticker-asset:///stream/capture-\(idx).png\" alt=\"Screenshot\"></p>",
                    type: .quote,
                    order: 0
                )
                let note = Cell(
                    streamId: stream.id,
                    content: "<p>Capture \(idx)</p>",
                    type: .text,
                    order: 0
                )
                let inserted = try service.insertQuickPanelCells(streamId: stream.id, cells: [quote, note])
                XCTAssertEqual(inserted[0].order + 1, inserted[1].order)
                capturePairs.append((quoteId: quote.id, noteId: note.id))
            }

            guard let loaded = try service.loadStream(id: stream.id) else {
                XCTFail("Expected stream to load")
                return
            }

            let sorted = loaded.cells.sorted { $0.order < $1.order }
            let ordersById = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.order) })

            for pair in capturePairs {
                guard let quoteOrder = ordersById[pair.quoteId], let noteOrder = ordersById[pair.noteId] else {
                    XCTFail("Missing persisted capture pair")
                    return
                }
                XCTAssertEqual(quoteOrder + 1, noteOrder)
            }

            XCTAssertEqual(sorted.last?.id, trailingEmpty.id)
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
}

final class LibraryServiceFrontMatterTests: XCTestCase {
    func test_frontMatterRoundtrip_preservesBodyAndRecognizedKeys() {
        let tickerID = UUID()
        let tickerPDFID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_717_171_700)
        let body = "# Heading\n\nParagraph one.\nParagraph two.\n"

        let frontMatter = TickerNoteFrontMatter(
            tickerID: tickerID,
            tickerKind: .pdfNote,
            tickerPDFID: tickerPDFID,
            createdAt: createdAt
        )

        let serialized = TickerMarkdownFrontMatterCodec.serialize(frontMatter: frontMatter, body: body)
        let parsed = TickerMarkdownFrontMatterCodec.parse(serialized)

        XCTAssertEqual(parsed.frontMatter, frontMatter)
        XCTAssertEqual(parsed.body, body)
    }

    func test_detectDuplicateTickerIDs_groupsDeterministically() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let duplicateID = UUID()
        let distinctID = UUID()

        let fileA = tempDir.appendingPathComponent("01-a.md")
        let fileB = tempDir.appendingPathComponent("02-b.md")
        let fileC = tempDir.appendingPathComponent("03-c.md")

        try writeNote(fileA, id: duplicateID, body: "A body")
        try writeNote(fileB, id: duplicateID, body: "B body")
        try writeNote(fileC, id: distinctID, body: "C body")

        let suiteName = "LibraryServiceFrontMatterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let notes = try service.scanMarkdownNotes(in: tempDir)
        let duplicates = TickerNoteDuplicateResolver.detectDuplicateTickerIDs(in: notes)

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].tickerID, duplicateID)
        XCTAssertEqual(duplicates[0].fileURLs.map(\.lastPathComponent), ["01-a.md", "02-b.md"])
    }

    func test_fixDuplicateTickerIDs_rewritesOnlyConflictingFollowers() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let duplicateID = UUID()
        let uniqueID = UUID()

        let retainedURL = tempDir.appendingPathComponent("01-retained.md")
        let rewrittenURL = tempDir.appendingPathComponent("02-rewritten.md")
        let uniqueURL = tempDir.appendingPathComponent("03-unique.md")

        try writeNote(retainedURL, id: duplicateID, body: "retained body")
        try writeNote(rewrittenURL, id: duplicateID, body: "rewritten body")
        try writeNote(uniqueURL, id: uniqueID, body: "unique body")

        let suiteName = "LibraryServiceFixTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let result = try service.fixDuplicateTickerIDs(in: tempDir)

        XCTAssertEqual(result.rewrittenIDsByFile.count, 1)
        XCTAssertEqual(result.retainedFiles.map(\.lastPathComponent), ["01-retained.md"])
        let rewrittenFileNames = Set(result.rewrittenIDsByFile.keys.map(\.lastPathComponent))
        XCTAssertEqual(rewrittenFileNames, Set(["02-rewritten.md"]))

        let retainedParsed = TickerMarkdownFrontMatterCodec.parse(try String(contentsOf: retainedURL, encoding: .utf8))
        let rewrittenParsed = TickerMarkdownFrontMatterCodec.parse(try String(contentsOf: rewrittenURL, encoding: .utf8))
        let uniqueParsed = TickerMarkdownFrontMatterCodec.parse(try String(contentsOf: uniqueURL, encoding: .utf8))

        XCTAssertEqual(retainedParsed.frontMatter?.tickerID, duplicateID)
        XCTAssertNotEqual(rewrittenParsed.frontMatter?.tickerID, duplicateID)
        XCTAssertEqual(uniqueParsed.frontMatter?.tickerID, uniqueID)

        XCTAssertEqual(retainedParsed.body, "retained body")
        XCTAssertEqual(rewrittenParsed.body, "rewritten body")
        XCTAssertEqual(uniqueParsed.body, "unique body")
    }

    private func writeNote(_ url: URL, id: UUID, body: String) throws {
        let markdown = TickerMarkdownFrontMatterCodec.serialize(
            frontMatter: TickerNoteFrontMatter(
                tickerID: id,
                tickerKind: .note,
                tickerPDFID: nil,
                createdAt: nil
            ),
            body: body
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class LibraryServiceNoteFileTests: XCTestCase {
    func test_createLoadSaveNote_roundtripPreservesFrontMatterAndBody() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let suiteName = "LibraryServiceNoteFileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        try service.ensureLibraryStructure(at: tempDir)

        let created = try service.createNote(in: tempDir, title: "Daily Draft")
        XCTAssertEqual(created.url.lastPathComponent, "daily-draft.md")
        XCTAssertEqual(created.frontMatter.tickerKind, .note)
        XCTAssertTrue(fileManager.fileExists(atPath: created.url.path))

        var loaded = try service.loadNote(at: created.url)
        XCTAssertEqual(loaded.frontMatter.tickerID, created.frontMatter.tickerID)
        XCTAssertEqual(loaded.body, "")

        loaded.body = "# Daily Draft\n\nBody content."
        try service.saveNote(loaded)

        let reloaded = try service.loadNote(at: created.url)
        XCTAssertEqual(reloaded.frontMatter.tickerID, created.frontMatter.tickerID)
        XCTAssertEqual(reloaded.frontMatter.tickerKind, .note)
        XCTAssertEqual(reloaded.body, "# Daily Draft\n\nBody content.")
    }

    func test_createNote_sameTitleUsesDeterministicCollisionSuffixes() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let suiteName = "LibraryServiceCollisionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        try service.ensureLibraryStructure(at: tempDir)

        let first = try service.createNote(in: tempDir, title: "Meeting Notes")
        let second = try service.createNote(in: tempDir, title: "Meeting Notes")
        let third = try service.createNote(in: tempDir, title: "Meeting Notes")

        XCTAssertEqual(first.url.lastPathComponent, "meeting-notes.md")
        XCTAssertEqual(second.url.lastPathComponent, "meeting-notes-2.md")
        XCTAssertEqual(third.url.lastPathComponent, "meeting-notes-3.md")
    }
}

final class LibraryServiceCaptureAssetTests: XCTestCase {
    func test_ensureInboxNote_returnsInboxFrontMatterAndPersistsFile() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let suiteName = "LibraryServiceCaptureAssetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let inbox = try service.ensureInboxNote(in: tempDir)

        XCTAssertEqual(inbox.frontMatter.tickerKind, .inbox)
        XCTAssertEqual(inbox.url.lastPathComponent, "Inbox.md")
        XCTAssertTrue(fileManager.fileExists(atPath: inbox.url.path))
    }

    func test_saveImageAsset_and_relativePath_forNestedNote() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let suiteName = "LibraryServiceCaptureAssetPathTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        try service.ensureLibraryStructure(at: tempDir)

        let note = try service.createNote(in: tempDir, title: "Research", directoryRelativePath: "ProjectA")
        let imageURL = try service.saveImageAsset(data: Data([0x01, 0x02, 0x03]), in: tempDir)
        let relativePath = service.relativePath(from: note.url.deletingLastPathComponent(), to: imageURL)

        XCTAssertTrue(fileManager.fileExists(atPath: imageURL.path))
        XCTAssertTrue(relativePath.hasPrefix("../Assets/Images/"))
    }
}

final class LibraryServicePDFImportTests: XCTestCase {
    func test_importPDF_copiesAssetAndCreatesLinkedPDFNote() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let libraryRoot = tempDir.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = tempDir.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let sourcePDFURL = sourceRoot.appendingPathComponent("paper.pdf")
        let samplePDF = Data("%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try samplePDF.write(to: sourcePDFURL, options: [.atomic])

        let suiteName = "LibraryServicePDFImportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let imported = try service.importPDF(at: sourcePDFURL, in: libraryRoot)

        XCTAssertTrue(fileManager.fileExists(atPath: imported.importedURL.path))
        XCTAssertEqual(imported.importedURL.pathExtension.lowercased(), "pdf")
        XCTAssertTrue(imported.importedURL.path.contains("/Assets/PDFs/"))
        XCTAssertEqual(imported.note.frontMatter.tickerKind, .pdfNote)
        XCTAssertEqual(imported.note.frontMatter.tickerPDFID, imported.pdfID)

        let loaded = try service.loadNote(at: imported.note.url)
        XCTAssertEqual(loaded.frontMatter.tickerKind, .pdfNote)
        XCTAssertEqual(loaded.frontMatter.tickerPDFID, imported.pdfID)
    }

    func test_importPDF_persistsPDFMetadataAndMatchesInitialFingerprint() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let libraryRoot = tempDir.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = tempDir.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let sourcePDFURL = sourceRoot.appendingPathComponent("whitepaper.pdf")
        let samplePDF = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try samplePDF.write(to: sourcePDFURL, options: [.atomic])

        let suiteName = "LibraryServicePDFMetadataTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let imported = try service.importPDF(at: sourcePDFURL, in: libraryRoot)

        let metadata = try service.loadPDFMetadata(pdfID: imported.pdfID, in: libraryRoot)
        XCTAssertNotNil(metadata)

        let driftStatus = try service.inspectPDFDrift(for: imported.pdfID, in: libraryRoot)
        if case .matches = driftStatus {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected .matches after import, got \(driftStatus)")
        }
    }

    func test_inspectPDFDrift_reportsMissingMetadataAndDriftAfterMutation() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let libraryRoot = tempDir.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = tempDir.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let sourcePDFURL = sourceRoot.appendingPathComponent("spec.pdf")
        let originalPDF = Data("%PDF-1.4\n1 0 obj\n<< /Type /Page >>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try originalPDF.write(to: sourcePDFURL, options: [.atomic])

        let suiteName = "LibraryServicePDFDriftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let imported = try service.importPDF(at: sourcePDFURL, in: libraryRoot)

        let metadataURL = libraryRoot
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("pdfs", isDirectory: true)
            .appendingPathComponent("\(imported.pdfID.uuidString.lowercased()).json")

        try fileManager.removeItem(at: metadataURL)

        let missingMetadataStatus = try service.inspectPDFDrift(for: imported.pdfID, in: libraryRoot)
        switch missingMetadataStatus {
        case .missingMetadata(let current):
            XCTAssertGreaterThan(current.fileSize, 0)
        default:
            XCTFail("Expected .missingMetadata, got \(missingMetadataStatus)")
        }

        let reloadedFingerprint = try service.computePDFFingerprint(at: imported.importedURL)
        try service.savePDFMetadata(pdfID: imported.pdfID, fingerprint: reloadedFingerprint, in: libraryRoot)

        let mutatedPDF = Data("%PDF-1.4\n1 0 obj\n<< /Type /Page /Rotate 90 >>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try mutatedPDF.write(to: imported.importedURL, options: [.atomic])

        let driftStatus = try service.inspectPDFDrift(for: imported.pdfID, in: libraryRoot)
        switch driftStatus {
        case .drifted(let expected, let current):
            XCTAssertNotEqual(expected.sha256Hex, current.sha256Hex)
        default:
            XCTFail("Expected .drifted, got \(driftStatus)")
        }
    }

    func test_appendPDFHighlight_persistsAndCanReloadByID() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let libraryRoot = tempDir.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = tempDir.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let sourcePDFURL = sourceRoot.appendingPathComponent("annotate.pdf")
        let basePDF = Data("%PDF-1.4\n1 0 obj\n<< /Type /Page >>\nendobj\ntrailer\n<<>>\n%%EOF\n".utf8)
        try basePDF.write(to: sourcePDFURL, options: [.atomic])

        let suiteName = "LibraryServicePDFHighlightTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = LibraryService(defaults: defaults, fileManager: fileManager)
        let imported = try service.importPDF(at: sourcePDFURL, in: libraryRoot)

        let highlightID = UUID()
        let highlight = TickerPDFHighlightAnchor(
            id: highlightID,
            pageIndex: 0,
            selectedText: "Example quote",
            rects: [TickerPDFHighlightRect(x: 12, y: 24, width: 120, height: 18)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try service.appendPDFHighlight(pdfID: imported.pdfID, highlight: highlight, in: libraryRoot)

        let loaded = try service.loadPDFHighlight(pdfID: imported.pdfID, highlightID: highlightID, in: libraryRoot)
        XCTAssertEqual(loaded, highlight)

        let allHighlights = try service.loadPDFHighlights(pdfID: imported.pdfID, in: libraryRoot)
        XCTAssertEqual(allHighlights.count, 1)
        XCTAssertEqual(allHighlights.first, highlight)
    }

    func test_pdfLinkCodec_roundtripAndOffsetMatching() {
        let pdfID = UUID()
        let highlightID = UUID()
        let url = TickerPDFLinkCodec.makeURLString(pdfID: pdfID, highlightID: highlightID)

        let parsed = TickerPDFLinkCodec.parse(urlString: url)
        XCTAssertEqual(parsed?.pdfID, pdfID)
        XCTAssertEqual(parsed?.highlightID, highlightID)

        let text = "Before \(url) after"
        let nsText = text as NSString
        let linkRange = nsText.range(of: url)
        XCTAssertNotEqual(linkRange.location, NSNotFound)

        let offsetInsideLink = linkRange.location + 4
        let match = TickerPDFLinkCodec.match(in: text, containingUTF16Offset: offsetInsideLink)
        XCTAssertEqual(match?.urlString, url)
        XCTAssertEqual(match?.pdfID, pdfID)
        XCTAssertEqual(match?.highlightID, highlightID)

        let matchAtStart = TickerPDFLinkCodec.match(in: text, containingUTF16Offset: linkRange.location)
        XCTAssertEqual(matchAtStart?.urlString, url)

        let matchAtEnd = TickerPDFLinkCodec.match(in: text, containingUTF16Offset: NSMaxRange(linkRange))
        XCTAssertEqual(matchAtEnd?.urlString, url)

        let markdownSnippet = "[Example](\(url))"
        let firstMatch = TickerPDFLinkCodec.firstMatch(in: markdownSnippet)
        XCTAssertEqual(firstMatch?.urlString, url)

        let outsideMatch = TickerPDFLinkCodec.match(in: text, containingUTF16Offset: NSMaxRange(linkRange) + 1)
        XCTAssertNil(outsideMatch)
    }
}
