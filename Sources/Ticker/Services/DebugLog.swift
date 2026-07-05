import Foundation

final class LogRing {
    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func append(_ message: String, date: Date = Date()) {
        guard capacity > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let line = "\(formatter.string(from: date)) \(message)"
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        return lines
    }

    func joined(maxBytes: Int) -> String {
        let joined = snapshot().joined(separator: "\n")
        let bytes = Data(joined.utf8)
        guard maxBytes > 0, bytes.count > maxBytes else {
            return joined
        }
        return String(decoding: bytes.suffix(maxBytes), as: UTF8.self)
    }
}

enum CrashSessionSentinel {
    struct LaunchResult: Equatable {
        let lastSessionCrashed: Bool
        let markerWriteSucceeded: Bool
    }

    private static let lock = NSLock()
    private static var storedLastSessionCrashed = false

    static var lastSessionCrashed: Bool {
        lock.lock()
        let value = storedLastSessionCrashed
        lock.unlock()
        return value
    }

    static func evaluateLaunch(markerExisted: Bool, markerWriteSucceeded: Bool) -> LaunchResult {
        LaunchResult(
            lastSessionCrashed: markerExisted,
            markerWriteSucceeded: markerWriteSucceeded
        )
    }

    static func defaultMarkerURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Ticker-Next", isDirectory: true)
            .appendingPathComponent("session.lock")
    }

    @discardableResult
    static func markLaunch(markerURL: URL = defaultMarkerURL(), fileManager: FileManager = .default) -> LaunchResult {
        let markerExisted = fileManager.fileExists(atPath: markerURL.path)
        var markerWriteSucceeded = false

        do {
            let markerDirectory = markerURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: markerDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: markerDirectory.path)
            let payload = "pid=\(ProcessInfo.processInfo.processIdentifier) started_at=\(ISO8601DateFormatter().string(from: Date()))"
            try payload.write(to: markerURL, atomically: true, encoding: .utf8)
            markerWriteSucceeded = true
        } catch {
            markerWriteSucceeded = false
        }

        let result = evaluateLaunch(
            markerExisted: markerExisted,
            markerWriteSucceeded: markerWriteSucceeded
        )
        setLastSessionCrashed(result.lastSessionCrashed)

        if result.lastSessionCrashed {
            DebugLog.log("[Ticker] Previous session marker found lastSessionCrashed=true")
        }

        return result
    }

    static func markCleanTermination(markerURL: URL = defaultMarkerURL(), fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: markerURL)
        setLastSessionCrashed(false)
    }

    static func setLastSessionCrashedForTesting(_ crashed: Bool) {
        setLastSessionCrashed(crashed)
    }

    private static func setLastSessionCrashed(_ crashed: Bool) {
        lock.lock()
        storedLastSessionCrashed = crashed
        lock.unlock()
    }
}

/// Metadata-only diagnostics helper.
///
/// Policy:
/// - Log metadata only: counts, ids, flags, states, error domains/codes, and timings.
/// - Never log document text, selected text, prompts, device keys, screenshots, or file contents.
/// - Prefer user-visible errors (toasts/alerts) plus support bundles, not console logs.
enum DebugLog {
    private static let ring = LogRing(capacity: 300)

    static func log(_ message: @autoclosure () -> String) {
        let rendered = message()
        ring.append(rendered)
#if DEBUG
        print(rendered)
#endif
    }

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code)"
    }

    static func recentLines(maxBytes: Int = 16 * 1024) -> String {
        ring.joined(maxBytes: maxBytes)
    }
}
