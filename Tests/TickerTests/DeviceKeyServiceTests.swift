import XCTest

@testable import Ticker

final class DeviceKeyServiceTests: XCTestCase {
    func test_logRingCapsAndPreservesOrder() {
        let ring = LogRing(capacity: 3)

        for i in 0..<5 {
            ring.append("line-\(i)", date: Date(timeIntervalSince1970: TimeInterval(i)))
        }

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertTrue(snapshot[0].contains("line-2"))
        XCTAssertTrue(snapshot[1].contains("line-3"))
        XCTAssertTrue(snapshot[2].contains("line-4"))
        XCTAssertLessThanOrEqual(Data(ring.joined(maxBytes: 20).utf8).count, 20)
    }

    func test_logRingThreadSafetySmoke() {
        let ring = LogRing(capacity: 1_000)

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            ring.append("line-\(index)")
        }

        XCTAssertEqual(ring.snapshot().count, 1_000)
    }

    func test_crashSessionSentinelEvaluateLaunch() {
        XCTAssertEqual(
            CrashSessionSentinel.evaluateLaunch(markerExisted: true, markerWriteSucceeded: true),
            CrashSessionSentinel.LaunchResult(lastSessionCrashed: true, markerWriteSucceeded: true)
        )
        XCTAssertEqual(
            CrashSessionSentinel.evaluateLaunch(markerExisted: false, markerWriteSucceeded: false),
            CrashSessionSentinel.LaunchResult(lastSessionCrashed: false, markerWriteSucceeded: false)
        )
    }

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

    func test_getSupportBundle_includesLogsCrashUptimeAndCrashSentinel() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let diagnosticReportsDir = tempDir.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try fileManager.createDirectory(at: diagnosticReportsDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentCrashURL = diagnosticReportsDir.appendingPathComponent("TickerNext-2026-07-05-133000.ips")
        let staleCrashURL = diagnosticReportsDir.appendingPathComponent("TickerNext-2026-06-01-133000.ips")
        let otherCrashURL = diagnosticReportsDir.appendingPathComponent("OtherApp-2026-07-05-133000.ips")
        let recentCrashPayload = "newest crash header\n" + String(repeating: "x", count: 40 * 1024)

        try recentCrashPayload.write(to: recentCrashURL, atomically: true, encoding: .utf8)
        try "stale crash".write(to: staleCrashURL, atomically: true, encoding: .utf8)
        try "other crash".write(to: otherCrashURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentCrashURL.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))],
            ofItemAtPath: staleCrashURL.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: otherCrashURL.path
        )

        let fileURL = tempDir.appendingPathComponent("device.json")
        let service = DeviceKeyService(
            fileURL: fileURL,
            diagnosticReportsDirectoryURL: diagnosticReportsDir,
            launchDate: now.addingTimeInterval(-65),
            nowProvider: { now },
            recentLogsProvider: { "log-a\nlog-b" },
            lastSessionCrashedProvider: { true }
        )

        _ = await service.loadProxyAuth()
        let bundle = await service.getSupportBundle()

        XCTAssertEqual(bundle["recent_logs"] as? String, "log-a\nlog-b")
        XCTAssertEqual(bundle["uptime_seconds"] as? Int, 65)
        XCTAssertEqual(bundle["last_session_crashed"] as? Bool, true)

        let recentCrash = try XCTUnwrap(bundle["recent_crash"] as? String)
        XCTAssertTrue(recentCrash.contains("newest crash header"))
        XCTAssertFalse(recentCrash.contains("stale crash"))
        XCTAssertLessThanOrEqual(Data(recentCrash.utf8).count, SupportDiagnostics.recentCrashMaxBytes)
    }
}
