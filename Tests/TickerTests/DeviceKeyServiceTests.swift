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
