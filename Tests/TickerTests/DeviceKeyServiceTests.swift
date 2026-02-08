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
