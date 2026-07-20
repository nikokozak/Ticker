import AppKit
import Darwin
import UniformTypeIdentifiers

/// Service for detecting clipboard content
enum ClipboardService {

    /// Track last known change count and when it changed
    private struct ChangeTracker {
        var lastChangeCount: Int
        var lastChangeTime: Date
    }

    private static var changeTrackers: [NSPasteboard.Name: ChangeTracker] = [
        .general: ChangeTracker(
            lastChangeCount: NSPasteboard.general.changeCount,
            lastChangeTime: .distantPast
        )
    ]

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Get current clipboard text
    static func getText(pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.string(forType: .string)
    }

    /// Get current clipboard image
    static func getImage(pasteboard: NSPasteboard = .general) -> NSImage? {
        // Check for image types
        if let image = NSImage(pasteboard: pasteboard) {
            return image
        }

        // Check for file URLs that are images
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        return nil
    }

    /// Get current clipboard image data without inflating Tahoe HEIF captures to PNG.
    static func getImageData(pasteboard: NSPasteboard = .general) -> Data? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let contentType = UTType(type.rawValue),
                      contentType.conforms(to: .image),
                      let data = item.data(forType: type),
                      (try? ImageImportPolicy.metadata(for: data)) != nil else {
                    continue
                }
                return data
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                guard (try? ImageImportPolicy.validateFileSize(at: url)) != nil,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      (try? ImageImportPolicy.metadata(for: data)) != nil else {
                    continue
                }
                return data
            }
        }

        guard let image = getImage(pasteboard: pasteboard) else { return nil }

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]),
              (try? ImageImportPolicy.metadata(for: pngData)) != nil else {
            return nil
        }

        return pngData
    }

    /// Read the newest macOS-tagged screenshot when Screenshot is configured to save files.
    static func getRecentScreenshotData(
        in directory: URL? = nil,
        maxAge: TimeInterval = 10,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Data? {
        guard maxAge >= 0,
              let directory = directory ?? screenshotDirectory(fileManager: fileManager),
              let files = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let candidates = files.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .contentTypeKey,
                .isRegularFileKey,
            ]),
            values.isRegularFile == true,
            values.contentType?.conforms(to: .image) == true,
            let date = values.contentModificationDate,
            now.timeIntervalSince(date) >= -1,
            now.timeIntervalSince(date) <= maxAge,
            hasScreenshotMetadata(at: url) else {
                return nil
            }
            return (url, date)
        }.sorted { $0.date > $1.date }

        for candidate in candidates {
            guard (try? ImageImportPolicy.validateFileSize(at: candidate.url)) != nil,
                  let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe),
                  (try? ImageImportPolicy.metadata(for: data)) != nil else {
                continue
            }
            return data
        }

        return nil
    }

    /// Get clipboard change count (to detect changes)
    static func changeCount(pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.changeCount
    }

    /// Check if clipboard was recently modified (within threshold)
    /// Updates internal tracking on each call
    static func wasRecentlyModified(
        threshold: TimeInterval = 60,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        let currentCount = pasteboard.changeCount
        var tracker = changeTracker(for: pasteboard)

        // If change count differs, clipboard was modified
        if currentCount != tracker.lastChangeCount {
            tracker.lastChangeCount = currentCount
            tracker.lastChangeTime = Date()
            changeTrackers[pasteboard.name] = tracker
            return true
        }

        // Check if last change was within threshold
        changeTrackers[pasteboard.name] = tracker
        return Date().timeIntervalSince(tracker.lastChangeTime) < threshold
    }

    /// A synthetic copy/restore cycle can bump changeCount without being user intent.
    /// Sync the count while preserving lastChangeTime so only genuine copies remain recent.
    static func syncChangeCount(pasteboard: NSPasteboard = .general) {
        var tracker = changeTracker(for: pasteboard)
        tracker.lastChangeCount = pasteboard.changeCount
        changeTrackers[pasteboard.name] = tracker
    }

    static func hasConcealedOrTransientTypes(pasteboard: NSPasteboard = .general) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(concealedType) || types.contains(transientType)
    }

    private static func screenshotDirectory(fileManager: FileManager) -> URL? {
        if let path = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private static func hasScreenshotMetadata(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return "com.apple.metadata:kMDItemIsScreenCapture".withCString {
                getxattr(path, $0, nil, 0, 0, 0) > 0
            }
        }
    }

    private static func changeTracker(for pasteboard: NSPasteboard) -> ChangeTracker {
        if let tracker = changeTrackers[pasteboard.name] {
            return tracker
        }

        let tracker = ChangeTracker(
            lastChangeCount: pasteboard.changeCount,
            lastChangeTime: .distantPast
        )
        changeTrackers[pasteboard.name] = tracker
        return tracker
    }
}
