import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageImportPolicy {
    static let maxByteCount = 25 * 1024 * 1024
    static let maxPixelDimension = 12_000
    static let maxPixelCount = 64_000_000
    static let maxBase64CharacterCount = ((maxByteCount + 2) / 3) * 4

    struct Metadata {
        let fileExtension: String
        let width: Int
        let height: Int
    }

    static func data(fromBase64 encoded: String) throws -> Data {
        guard encoded.utf8.count <= maxBase64CharacterCount else {
            throw ImageImportError.tooManyBytes
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw ImageImportError.invalidImage
        }
        return data
    }

    static func validateFileSize(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw ImageImportError.unreadableSize
        }
        guard fileSize <= maxByteCount else {
            throw ImageImportError.tooManyBytes
        }
    }

    static func metadata(for data: Data) throws -> Metadata {
        guard data.count <= maxByteCount else {
            throw ImageImportError.tooManyBytes
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension else {
            throw ImageImportError.invalidImage
        }

        guard width <= maxPixelDimension,
              height <= maxPixelDimension,
              Int64(width) * Int64(height) <= Int64(maxPixelCount) else {
            throw ImageImportError.tooManyPixels
        }

        return Metadata(fileExtension: fileExtension, width: width, height: height)
    }
}

enum ImageImportError: LocalizedError {
    case invalidImage
    case tooManyBytes
    case tooManyPixels
    case unreadableSize

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That file is not a supported image."
        case .tooManyBytes:
            return "Images must be 25 MB or smaller."
        case .tooManyPixels:
            return "That image's dimensions are too large."
        case .unreadableSize:
            return "Could not determine the image size."
        }
    }
}

/// Manages stream assets (images, files) stored locally
final class AssetService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let assetsBaseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.assetsBaseDirectory = baseDirectory
            return
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.assetsBaseDirectory = appSupport.appendingPathComponent("Ticker-Next/assets", isDirectory: true)
    }

    /// Get the assets directory for a specific stream
    func assetsDirectory(for streamId: UUID) -> URL {
        assetsBaseDirectory.appendingPathComponent(streamId.uuidString, isDirectory: true)
    }

    /// Ensure the assets directory exists for a stream
    func ensureAssetsDirectory(for streamId: UUID) throws {
        let directory = assetsDirectory(for: streamId)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Save image data to the stream's assets folder
    /// Returns the relative path from assets base (for storage in cell content)
    func saveImage(data: Data, streamId: UUID) throws -> String {
        let metadata = try ImageImportPolicy.metadata(for: data)
        try ensureAssetsDirectory(for: streamId)

        let directory = assetsDirectory(for: streamId)
        let finalFilename = "\(UUID().uuidString).\(metadata.fileExtension)"
        let fileURL = directory.appendingPathComponent(finalFilename)
        try data.write(to: fileURL, options: .atomic)

        // Return relative path: streamId/filename
        return "\(streamId.uuidString)/\(finalFilename)"
    }

    /// Save an image from a file URL (copies to assets folder)
    func saveImage(from sourceURL: URL, streamId: UUID) throws -> String {
        try ImageImportPolicy.validateFileSize(at: sourceURL)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return try saveImage(data: data, streamId: streamId)
    }

    /// Get the full file URL for an asset path
    func assetURL(for relativePath: String) -> URL {
        assetsBaseDirectory.appendingPathComponent(relativePath)
    }

    /// Delete all assets for a stream
    func deleteAssets(for streamId: UUID) throws {
        let directory = assetsDirectory(for: streamId)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Delete a specific asset
    func deleteAsset(relativePath: String) throws {
        let fileURL = assetURL(for: relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    /// Convert a ticker-asset:// URL to a data URL for API consumption
    /// Images are resized to max 2048px (longest edge) to keep payloads reasonable while preserving text readability
    /// Returns nil if the file doesn't exist, can't be read, or is outside the assets directory
    func assetToDataURL(_ assetURL: String) -> String? {
        // Parse ticker-asset:// URL to get file path
        guard assetURL.hasPrefix("ticker-asset://") else { return nil }

        var filePath = String(assetURL.dropFirst("ticker-asset://".count))
        // Handle triple-slash URLs (ticker-asset:///path) - remove leading slash
        if filePath.hasPrefix("/") {
            filePath = String(filePath.dropFirst())
        }

        // Support both absolute paths (legacy) and relative paths (portable)
        let requestedURL: URL
        if filePath.hasPrefix("Users/") || filePath.hasPrefix("var/") {
            // Absolute path (legacy format) - add leading slash back
            requestedURL = URL(fileURLWithPath: "/" + filePath)
        } else {
            // Relative path (portable format): e.g., "streamId/filename.png"
            requestedURL = assetsBaseDirectory.appendingPathComponent(filePath)
        }

        // Security: Canonicalize paths to prevent directory traversal attacks
        let canonicalPath = requestedURL.standardized.resolvingSymlinksInPath().path
        let canonicalBase = assetsBaseDirectory.standardized.resolvingSymlinksInPath().path

        // Verify the requested path is within the assets directory
        guard canonicalPath.hasPrefix(canonicalBase + "/") else {
            DebugLog.log("AssetService: Blocked path outside assets directory")
            return nil
        }

        let safeURL = URL(fileURLWithPath: canonicalPath)
        let data: Data
        let metadata: ImageImportPolicy.Metadata
        do {
            try ImageImportPolicy.validateFileSize(at: safeURL)
            data = try Data(contentsOf: safeURL, options: .mappedIfSafe)
            metadata = try ImageImportPolicy.metadata(for: data)
        } catch {
            DebugLog.log("AssetService: Could not read asset file (\(DebugLog.errorSummary(error)))")
            return nil
        }

        // Resize image if needed and convert to JPEG for efficient encoding
        guard let (finalData, mimeType) = resizeImageForAPI(
            data: data,
            metadata: metadata,
            maxDimension: 2048
        ) else {
            return nil
        }

        // Convert to data URL
        let base64 = finalData.base64EncodedString()
        return "data:\(mimeType);base64,\(base64)"
    }

    /// Convert multiple asset URLs to data URLs
    func assetsToDataURLs(_ assetURLs: [String]) -> [String] {
        assetURLs.compactMap { assetToDataURL($0) }
    }

    // MARK: - Private Helpers

    /// Resize image data if it exceeds maxDimension on longest edge
    /// Returns (resized data, mime type) - uses JPEG for resized images to reduce size
    private func resizeImageForAPI(
        data: Data,
        metadata: ImageImportPolicy.Metadata,
        maxDimension: Int
    ) -> (Data, String)? {
        let longestEdge = max(metadata.width, metadata.height)

        // If image is already small enough, return original with detected type
        if longestEdge <= maxDimension {
            return (data, mimeType(for: metadata.fileExtension))
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
              ] as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "image/jpeg")
    }

    /// Get MIME type for file extension
    private func mimeType(for ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
