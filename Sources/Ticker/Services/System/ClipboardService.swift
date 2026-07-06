import AppKit

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

    /// Check if clipboard contains an image
    static func hasImage() -> Bool {
        let pasteboard = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        return pasteboard.canReadItem(withDataConformingToTypes: imageTypes.map { $0.rawValue })
    }

    /// Get current clipboard image
    static func getImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

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

    /// Get image as PNG data (for storage)
    static func getImageData(maxSize: Int = 5_000_000) -> Data? {
        guard let image = getImage() else { return nil }

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        // Only return if reasonable size
        guard pngData.count < maxSize else {
            DebugLog.log("[ClipboardService] Image too large: \(pngData.count) bytes")
            return nil
        }

        return pngData
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
