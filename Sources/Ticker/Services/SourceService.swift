import Foundation
import PDFKit
import Vision
import AppKit

/// Manages file sources: bookmarks, access, and legacy whole-document text extraction.
final class SourceService {
    private let persistence: PersistenceService

    init(persistence: PersistenceService) {
        self.persistence = persistence
    }

    // MARK: - Bookmark Creation

    /// Create a source from a file URL, generating a security-scoped bookmark
    func createSource(from url: URL, for streamId: UUID) throws -> SourceReference {
        guard let fileType = SourceFileType(from: url) else {
            throw SourceError.unsupportedFileType(url.pathExtension)
        }

        // Create security-scoped bookmark
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let source = SourceReference(
            streamId: streamId,
            displayName: url.lastPathComponent,
            fileType: fileType,
            bookmarkData: bookmarkData,
            originalPath: url.path,
            status: .pending
        )

        // Save to database
        try persistence.saveSource(source)

        return source
    }

    // MARK: - File Access

    /// Resolve bookmark and access the file. Returns the accessible URL.
    /// Caller is responsible for calling `stopAccessingSecurityScopedResource()`.
    func accessFile(_ source: SourceReference) throws -> URL {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: source.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale - mark source and try to refresh
                var updated = source
                updated.status = .stale
                try? persistence.saveSource(updated)
            }

            guard url.startAccessingSecurityScopedResource() else {
                return try recoverAccessFromOriginalPath(source)
            }

            return url
        } catch let error as SourceError {
            throw error
        } catch {
            if let recoveredURL = try? recoverAccessFromOriginalPath(source) {
                return recoveredURL
            }
            throw SourceError.accessUnavailable(source.displayName)
        }
    }

    private func recoverAccessFromOriginalPath(_ source: SourceReference) throws -> URL {
        guard let originalPath = source.originalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !originalPath.isEmpty else {
            throw SourceError.accessUnavailable(source.displayName)
        }

        let url = URL(fileURLWithPath: originalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SourceError.accessUnavailable(source.displayName)
        }

        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var updated = source
        updated.bookmarkData = bookmarkData
        updated.status = updated.extractedText == nil ? .pending : .ready
        try persistence.saveSource(updated)

        guard url.startAccessingSecurityScopedResource() else {
            throw SourceError.accessUnavailable(source.displayName)
        }

        return url
    }

    /// Check if a source is still accessible
    func checkStatus(_ source: SourceReference) -> SourceStatus {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: source.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                return .stale
            }

            // Try to access
            if url.startAccessingSecurityScopedResource() {
                url.stopAccessingSecurityScopedResource()
                return source.extractedText != nil ? .ready : .pending
            } else {
                return .stale
            }
        } catch {
            return .error
        }
    }

    // MARK: - Text Extraction

    /// Extract text from a source file
    func extractText(from source: SourceReference) throws -> (text: String, pageCount: Int?) {
        let url = try accessFile(source)
        defer { url.stopAccessingSecurityScopedResource() }

        switch source.fileType {
        case .pdf:
            return try extractPDFText(from: url)
        case .text, .markdown:
            let text = try String(contentsOf: url, encoding: .utf8)
            return (text, nil)
        case .image:
            return try extractImageText(from: url)
        }
    }

    private func extractPDFText(from url: URL) throws -> (text: String, pageCount: Int?) {
        guard let document = PDFDocument(url: url) else {
            throw SourceError.extractionFailed("Could not open PDF")
        }

        let pageCount = document.pageCount
        var text = ""

        for i in 0..<pageCount {
            if let page = document.page(at: i),
               let pageText = page.string {
                if !text.isEmpty {
                    text += "\n\n--- Page \(i + 1) ---\n\n"
                }
                text += pageText
            }
        }

        return (text, pageCount)
    }

    private func extractImageText(from url: URL) throws -> (text: String, pageCount: Int?) {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SourceError.extractionFailed("Could not load image")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return ("", 1)
        }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        return (text, 1)
    }

    // MARK: - Full Processing

    /// Create and process a source: create bookmark, extract text, and save for the legacy whole-text AI path.
    func addSource(from url: URL, to streamId: UUID) throws -> SourceReference {
        // Create the source with bookmark
        var source = try createSource(from: url, for: streamId)

        // Extract text
        do {
            let (text, pageCount) = try extractText(from: source)
            source.extractedText = text.isEmpty ? nil : text
            source.pageCount = pageCount
            source.status = .ready
        } catch {
            source.status = .error
            DebugLog.log("Text extraction failed (\(DebugLog.errorSummary(error)))")
        }

        // Update in database
        try persistence.saveSource(source)

        return source
    }

    /// Remove a source
    func removeSource(id: UUID) throws {
        try persistence.deleteSource(id: id)
    }
}

// MARK: - Errors

enum SourceError: LocalizedError {
    case unsupportedFileType(String)
    case accessDenied(String)
    case accessUnavailable(String)
    case extractionFailed(String)
    case bookmarkStale(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: \(ext)"
        case .accessDenied(let name):
            return "Cannot access file: \(name)"
        case .accessUnavailable(let name):
            return "Can't access \(name) — the file may have moved. Re-add the source."
        case .extractionFailed(let reason):
            return "Text extraction failed: \(reason)"
        case .bookmarkStale(let name):
            return "File has moved or been deleted: \(name)"
        }
    }
}
