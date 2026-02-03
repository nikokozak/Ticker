import Foundation
import PDFKit
import Vision
import AppKit

/// Manages file sources: bookmarks, access, text extraction, and RAG processing
final class SourceService {
    private let persistence: PersistenceService
    private let chunkingService: ChunkingService
    private let embeddingService: EmbeddingService

    init(
        persistence: PersistenceService,
        chunkingService: ChunkingService = ChunkingService(),
        embeddingService: EmbeddingService = EmbeddingService()
    ) {
        self.persistence = persistence
        self.chunkingService = chunkingService
        self.embeddingService = embeddingService
    }

    /// Check if embedding service is configured (has OpenAI API key)
    var isEmbeddingConfigured: Bool {
        embeddingService.isConfigured
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
            throw SourceError.accessDenied(source.displayName)
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

    /// Create and process a source: create bookmark, extract text, save, and trigger RAG processing
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

        // Trigger RAG processing asynchronously if text was extracted
        if source.status == .ready, source.extractedText != nil {
            Task {
                await processSourceForRAG(source: source)
            }
        }

        return source
    }

    // MARK: - RAG Processing

    /// Process a source for RAG: chunk, embed, and store
    func processSourceForRAG(source: SourceReference) async {
        guard let text = source.extractedText, !text.isEmpty else {
            DebugLog.log("RAG: No text to process for sourceId=\(source.id)")
            return
        }

        guard embeddingService.isConfigured else {
            DebugLog.log("RAG: Embedding service not configured, skipping sourceId=\(source.id)")
            // Mark as unconfigured so UI can explain why indexing didn't run
            try? persistence.updateSourceEmbeddingStatus(source.id, status: "unconfigured")
            return
        }

        do {
            // Mark as processing
            try persistence.updateSourceEmbeddingStatus(source.id, status: "processing")
            DebugLog.log("RAG: Processing sourceId=\(source.id)...")

            // Chunk the document
            let chunks: [SourceChunk]
            if source.fileType == .pdf {
                // Re-access file for page-aware chunking
                do {
                    let url = try accessFile(source)
                    defer { url.stopAccessingSecurityScopedResource() }

                    if let document = PDFDocument(url: url) {
                        chunks = chunkingService.chunkPDF(document: document, sourceId: source.id)
                    } else {
                        chunks = chunkingService.chunkText(text: text, sourceId: source.id)
                    }
                } catch {
                    // Fall back to text-based chunking if file access fails
                    DebugLog.log("RAG: File access failed, using text-based chunking (\(DebugLog.errorSummary(error)))")
                    chunks = chunkingService.chunkText(text: text, sourceId: source.id)
                }
            } else {
                chunks = chunkingService.chunkText(text: text, sourceId: source.id)
            }

            guard !chunks.isEmpty else {
                DebugLog.log("RAG: No chunks generated for sourceId=\(source.id)")
                try persistence.updateSourceEmbeddingStatus(source.id, status: "failed")
                return
            }

            DebugLog.log("RAG: Generated \(chunks.count) chunks for sourceId=\(source.id)")

            // Save chunks
            try persistence.saveChunks(chunks)

            // Generate embeddings in batch
            let texts = chunks.map { $0.content }
            let embeddings = try await embeddingService.embedBatch(texts: texts)

            guard embeddings.count == chunks.count else {
                DebugLog.log("RAG: Embedding count mismatch for sourceId=\(source.id)")
                try persistence.updateSourceEmbeddingStatus(source.id, status: "failed")
                return
            }

            // Save embeddings
            for (chunk, embedding) in zip(chunks, embeddings) {
                try persistence.saveEmbedding(
                    chunkId: chunk.id,
                    embedding: embedding,
                    model: "text-embedding-3-small"
                )
            }

            // Mark complete
            try persistence.updateSourceEmbeddingStatus(source.id, status: "complete")
            DebugLog.log("RAG: Completed processing sourceId=\(source.id): \(chunks.count) chunks embedded")

        } catch {
            DebugLog.log("RAG: Processing failed for sourceId=\(source.id) (\(DebugLog.errorSummary(error)))")
            try? persistence.updateSourceEmbeddingStatus(source.id, status: "failed")
        }
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
    case extractionFailed(String)
    case bookmarkStale(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: \(ext)"
        case .accessDenied(let name):
            return "Cannot access file: \(name)"
        case .extractionFailed(let reason):
            return "Text extraction failed: \(reason)"
        case .bookmarkStale(let name):
            return "File has moved or been deleted: \(name)"
        }
    }
}
