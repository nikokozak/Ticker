import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler for serving local assets to WKWebView
/// Handles URLs like: ticker-asset:///path/to/image.png
/// Security: Only serves files within the assets directory to prevent path traversal attacks
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Base directory for all assets - must match AssetService.assetsBaseDirectory
    private static var assetsBaseDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Ticker-Next/assets", isDirectory: true)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let filePath = url.path

        // Support both absolute paths (legacy) and relative paths (portable)
        // Relative paths are resolved against the assets base directory
        let requestedURL: URL
        if filePath.hasPrefix("/Users/") || filePath.hasPrefix("/var/") {
            // Absolute path (legacy format)
            requestedURL = URL(fileURLWithPath: filePath)
        } else {
            // Relative path (portable format): e.g., "/streamId/filename.png"
            requestedURL = Self.assetsBaseDirectory.appendingPathComponent(filePath)
        }

        // Security: Canonicalize paths to prevent directory traversal attacks
        let canonicalPath = requestedURL.standardized.resolvingSymlinksInPath().path
        let canonicalBase = Self.assetsBaseDirectory.standardized.resolvingSymlinksInPath().path

        // Verify the requested path is within the assets directory
        guard canonicalPath.hasPrefix(canonicalBase + "/") else {
            DebugLog.log("AssetSchemeHandler: Blocked path outside assets directory")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let safeURL = URL(fileURLWithPath: canonicalPath)
            let data = try Data(contentsOf: safeURL)

            // Determine MIME type from file extension
            let mimeType = mimeType(for: safeURL.pathExtension)

            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            DebugLog.log("AssetSchemeHandler: Failed to read asset file (\(DebugLog.errorSummary(error)))")
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to clean up
    }

    private func mimeType(for ext: String) -> String {
        if let utType = UTType(filenameExtension: ext.lowercased()) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        // Fallback for common image types
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}
