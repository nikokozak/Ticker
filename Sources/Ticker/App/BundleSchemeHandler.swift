import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler for serving bundled web resources to WKWebView.
/// Handles URLs like: ticker-bundle:///index.html, ticker-bundle:///assets/index.js
/// This avoids file:// URL issues with ES modules and CORS in WKWebView.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The subdirectory within the app bundle where web resources are stored
    private let resourceSubdirectory = "Resources"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Get the path from the URL (e.g., "/index.html" or "/assets/index.js")
        var filePath = url.path
        if filePath.hasPrefix("/") {
            filePath = String(filePath.dropFirst())
        }
        if filePath.isEmpty {
            filePath = "index.html"
        }

        // Look up the resource in the bundle
        let pathComponents = filePath.components(separatedBy: "/")
        let fileName: String
        let subdir: String

        if pathComponents.count > 1 {
            fileName = pathComponents.last ?? filePath
            let subdirComponents = [resourceSubdirectory] + pathComponents.dropLast()
            subdir = subdirComponents.joined(separator: "/")
        } else {
            fileName = filePath
            subdir = resourceSubdirectory
        }

        // Split filename into name and extension
        let nameComponents = fileName.components(separatedBy: ".")
        let name: String
        let ext: String?
        if nameComponents.count > 1 {
            name = nameComponents.dropLast().joined(separator: ".")
            ext = nameComponents.last
        } else {
            name = fileName
            ext = nil
        }

        guard let resourceURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) else {
            DebugLog.log("BundleSchemeHandler: Resource not found: \(filePath) (looked in \(subdir)/\(name).\(ext ?? ""))")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            let mimeType = mimeType(for: resourceURL.pathExtension)

            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
            )

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            DebugLog.log("BundleSchemeHandler: Failed to read resource (\(DebugLog.errorSummary(error)))")
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
        // Fallback for common web types
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
