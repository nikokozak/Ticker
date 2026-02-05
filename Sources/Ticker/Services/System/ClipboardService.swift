import AppKit

/// Service for detecting clipboard content
enum ClipboardService {

    /// Track last known change count and when it changed
    private static var lastChangeCount: Int = NSPasteboard.general.changeCount
    private static var lastChangeTime: Date = Date.distantPast

    /// Get current clipboard text
    static func getText() -> String? {
        NSPasteboard.general.string(forType: .string)
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
    static func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Check if clipboard was recently modified (within threshold)
    /// Updates internal tracking on each call
    static func wasRecentlyModified(threshold: TimeInterval = 60) -> Bool {
        let currentCount = NSPasteboard.general.changeCount

        // If change count differs, clipboard was modified
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            lastChangeTime = Date()
            return true
        }

        // Check if last change was within threshold
        return Date().timeIntervalSince(lastChangeTime) < threshold
    }
}
