import Foundation
import AppKit
import CryptoKit

enum TickerNoteKind: String, Equatable {
    case note
    case inbox
    case pdfNote = "pdf_note"
}

struct TickerNoteFrontMatter: Equatable {
    var tickerID: UUID
    var tickerKind: TickerNoteKind
    var tickerPDFID: UUID?
    var createdAt: Date?
}

struct ParsedTickerMarkdown: Equatable {
    var frontMatter: TickerNoteFrontMatter?
    var body: String
}

struct TickerMarkdownNote: Equatable {
    var url: URL
    var frontMatter: TickerNoteFrontMatter
    var body: String
}

struct TickerImportedPDF: Equatable {
    var pdfID: UUID
    var sourceURL: URL
    var importedURL: URL
    var note: TickerMarkdownNote
}

struct TickerPDFFingerprint: Codable, Equatable {
    var fileSize: Int64
    var modificationTimestamp: TimeInterval
    var sha256Hex: String

    private enum CodingKeys: String, CodingKey {
        case fileSize = "file_size"
        case modificationTimestamp = "modification_timestamp"
        case sha256Hex = "sha256_hex"
    }
}

struct TickerPDFMetadata: Codable, Equatable {
    var schemaVersion: Int
    var pdfID: UUID
    var fingerprint: TickerPDFFingerprint
    var highlights: [TickerPDFHighlightAnchor]
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pdfID = "pdf_id"
        case fingerprint
        case highlights
        case updatedAt = "updated_at"
    }

    init(
        schemaVersion: Int,
        pdfID: UUID,
        fingerprint: TickerPDFFingerprint,
        highlights: [TickerPDFHighlightAnchor],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.pdfID = pdfID
        self.fingerprint = fingerprint
        self.highlights = highlights
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pdfID = try container.decode(UUID.self, forKey: .pdfID)
        fingerprint = try container.decode(TickerPDFFingerprint.self, forKey: .fingerprint)
        highlights = try container.decodeIfPresent([TickerPDFHighlightAnchor].self, forKey: .highlights) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pdfID, forKey: .pdfID)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum TickerPDFDriftStatus: Equatable {
    case matches
    case missingFile
    case missingMetadata(current: TickerPDFFingerprint)
    case drifted(expected: TickerPDFFingerprint, current: TickerPDFFingerprint)
}

struct TickerPDFHighlightRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct TickerPDFHighlightAnchor: Codable, Equatable {
    var id: UUID
    var pageIndex: Int
    var selectedText: String
    var rects: [TickerPDFHighlightRect]
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case pageIndex = "page_index"
        case selectedText = "selected_text"
        case rects
        case createdAt = "created_at"
    }
}

struct TickerPDFLinkMatch: Equatable {
    var urlString: String
    var range: NSRange
    var pdfID: UUID
    var highlightID: UUID
}

enum TickerPDFLinkCodec {
    private static let linkPattern = #"ticker-pdf://([0-9a-fA-F-]{36})#hl=([0-9a-fA-F-]{36})"#
    private static let linkRegex = try! NSRegularExpression(pattern: linkPattern, options: [])

    static func makeURLString(pdfID: UUID, highlightID: UUID) -> String {
        "ticker-pdf://\(pdfID.uuidString.lowercased())#hl=\(highlightID.uuidString.lowercased())"
    }

    static func parse(urlString: String) -> (pdfID: UUID, highlightID: UUID)? {
        let nsString = urlString as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard let match = linkRegex.firstMatch(in: urlString, options: [], range: fullRange),
              match.range.location == 0,
              match.range.length == fullRange.length else {
            return nil
        }

        let pdfIDString = nsString.substring(with: match.range(at: 1))
        let highlightIDString = nsString.substring(with: match.range(at: 2))
        guard let pdfID = UUID(uuidString: pdfIDString),
              let highlightID = UUID(uuidString: highlightIDString) else {
            return nil
        }
        return (pdfID, highlightID)
    }

    static func match(in text: String, containingUTF16Offset offset: Int) -> TickerPDFLinkMatch? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = linkRegex.matches(in: text, options: [], range: fullRange)

        for match in matches {
            let range = match.range(at: 0)
            guard NSLocationInRange(offset, range) else { continue }
            let urlString = nsText.substring(with: range)
            guard let parsed = parse(urlString: urlString) else { continue }
            return TickerPDFLinkMatch(
                urlString: urlString,
                range: range,
                pdfID: parsed.pdfID,
                highlightID: parsed.highlightID
            )
        }

        return nil
    }
}

struct DuplicateTickerIDGroup: Equatable {
    var tickerID: UUID
    var fileURLs: [URL]
}

struct DuplicateTickerIDFixResult: Equatable {
    var rewrittenIDsByFile: [URL: UUID]
    var retainedFiles: [URL]
}

enum TickerMarkdownFrontMatterCodec {
    private static let frontMatterRegex = try! NSRegularExpression(
        pattern: #"(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)"#,
        options: []
    )
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ markdown: String) -> ParsedTickerMarkdown {
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        guard let match = frontMatterRegex.firstMatch(in: markdown, options: [], range: fullRange),
              match.range.location == 0 else {
            return ParsedTickerMarkdown(frontMatter: nil, body: markdown)
        }

        let headerBlock = nsMarkdown.substring(with: match.range(at: 1))
        let bodyStart = match.range.location + match.range.length
        let body = bodyStart < nsMarkdown.length ? nsMarkdown.substring(from: bodyStart) : ""

        var tickerID: UUID?
        var tickerKind: TickerNoteKind?
        var tickerPDFID: UUID?
        var createdAt: Date?

        for rawLine in headerBlock.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let separatorIndex = line.firstIndex(of: ":") else { continue }

            let rawKey = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(rawValue))

            switch rawKey {
            case "ticker_id":
                tickerID = UUID(uuidString: value)
            case "ticker_kind":
                tickerKind = TickerNoteKind(rawValue: value)
            case "ticker_pdf_id":
                tickerPDFID = UUID(uuidString: value)
            case "created_at":
                createdAt = parseISODate(value)
            default:
                continue
            }
        }

        guard let tickerID, let tickerKind else {
            return ParsedTickerMarkdown(frontMatter: nil, body: body)
        }

        return ParsedTickerMarkdown(
            frontMatter: TickerNoteFrontMatter(
                tickerID: tickerID,
                tickerKind: tickerKind,
                tickerPDFID: tickerPDFID,
                createdAt: createdAt
            ),
            body: body
        )
    }

    static func serialize(frontMatter: TickerNoteFrontMatter?, body: String) -> String {
        guard let frontMatter else { return body }

        var lines: [String] = [
            "---",
            "ticker_id: \(frontMatter.tickerID.uuidString.lowercased())",
            "ticker_kind: \(frontMatter.tickerKind.rawValue)"
        ]

        if let tickerPDFID = frontMatter.tickerPDFID {
            lines.append("ticker_pdf_id: \(tickerPDFID.uuidString.lowercased())")
        }

        if let createdAt = frontMatter.createdAt {
            lines.append("created_at: \(dateFormatter.string(from: createdAt))")
        }

        lines.append("---")
        let header = lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }

    private static func parseISODate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return dateFormatter.date(from: value)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

enum TickerNoteDuplicateResolver {
    static func detectDuplicateTickerIDs(in notes: [TickerMarkdownNote]) -> [DuplicateTickerIDGroup] {
        let orderedNotes = notes.sorted { $0.url.path < $1.url.path }
        let grouped = Dictionary(grouping: orderedNotes, by: { $0.frontMatter.tickerID })

        return grouped
            .compactMap { tickerID, groupedNotes in
                guard groupedNotes.count > 1 else { return nil }
                return DuplicateTickerIDGroup(
                    tickerID: tickerID,
                    fileURLs: groupedNotes.map(\.url)
                )
            }
            .sorted { $0.tickerID.uuidString < $1.tickerID.uuidString }
    }

    @discardableResult
    static func fixDuplicateTickerIDs(
        in notes: [TickerMarkdownNote],
        writer: (URL, String) throws -> Void = { url, markdown in
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    ) throws -> DuplicateTickerIDFixResult {
        let duplicateGroups = detectDuplicateTickerIDs(in: notes)
        guard !duplicateGroups.isEmpty else {
            return DuplicateTickerIDFixResult(rewrittenIDsByFile: [:], retainedFiles: [])
        }

        let notesByPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.url.path, $0) })
        var rewrittenIDsByFile: [URL: UUID] = [:]
        var retainedFiles: [URL] = []

        for group in duplicateGroups {
            let orderedPaths = group.fileURLs.map(\.path).sorted()
            guard let retainedPath = orderedPaths.first,
                  let retainedNote = notesByPath[retainedPath] else { continue }

            retainedFiles.append(retainedNote.url)

            for path in orderedPaths.dropFirst() {
                guard let note = notesByPath[path] else { continue }
                var updatedFrontMatter = note.frontMatter
                let updatedID = UUID()
                updatedFrontMatter.tickerID = updatedID

                let rewrittenMarkdown = TickerMarkdownFrontMatterCodec.serialize(
                    frontMatter: updatedFrontMatter,
                    body: note.body
                )
                try writer(note.url, rewrittenMarkdown)
                rewrittenIDsByFile[note.url] = updatedID
            }
        }

        return DuplicateTickerIDFixResult(
            rewrittenIDsByFile: rewrittenIDsByFile,
            retainedFiles: retainedFiles.sorted { $0.path < $1.path }
        )
    }
}

enum LibraryServiceError: Error {
    case missingLibraryBookmark
    case accessDenied
}

final class LibraryService {
    static let shared = LibraryService()

    private enum Keys {
        static let libraryRootBookmark = "ticker_next_library_root_bookmark"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var hasLibraryRootBookmark: Bool {
        defaults.data(forKey: Keys.libraryRootBookmark) != nil
    }

    func selectLibraryRootInteractively() throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a Ticker Next library folder."

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        try saveLibraryRootBookmark(for: selectedURL)
        try ensureLibraryStructure(at: selectedURL)
        return selectedURL
    }

    func saveLibraryRootBookmark(for rootURL: URL) throws {
        let bookmarkData = try rootURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: Keys.libraryRootBookmark)
    }

    func resolveLibraryRootURL() throws -> URL? {
        guard let bookmarkData = defaults.data(forKey: Keys.libraryRootBookmark) else {
            return nil
        }

        var bookmarkIsStale = false
        let rootURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )

        if bookmarkIsStale {
            try saveLibraryRootBookmark(for: rootURL)
        }

        return rootURL
    }

    func withLibraryRootAccess<T>(_ body: (URL) throws -> T) throws -> T? {
        guard let rootURL = try resolveLibraryRootURL() else {
            return nil
        }

        let didAccessSecurityScope = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        return try body(rootURL)
    }

    func ensureLibraryStructure(at rootURL: URL) throws {
        let requiredDirectories = [
            "Assets",
            "Assets/PDFs",
            "Assets/Images",
            ".ticker",
            ".ticker/meta",
            ".ticker/meta/docs",
            ".ticker/meta/pdfs",
            ".ticker/cache"
        ]

        for relativePath in requiredDirectories {
            let directoryURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let inboxURL = rootURL.appendingPathComponent("Inbox.md")
        if !fileManager.fileExists(atPath: inboxURL.path) {
            let inboxMarkdown = TickerMarkdownFrontMatterCodec.serialize(
                frontMatter: TickerNoteFrontMatter(
                    tickerID: UUID(),
                    tickerKind: .inbox,
                    tickerPDFID: nil,
                    createdAt: Date()
                ),
                body: ""
            )
            try inboxMarkdown.write(to: inboxURL, atomically: true, encoding: .utf8)
        }
    }

    func inboxNoteURL(in rootURL: URL) -> URL {
        rootURL.appendingPathComponent("Inbox.md")
    }

    func ensureInboxNote(in rootURL: URL) throws -> TickerMarkdownNote {
        try ensureLibraryStructure(at: rootURL)
        let inboxURL = inboxNoteURL(in: rootURL)
        return try loadNote(at: inboxURL)
    }

    func saveImageAsset(data: Data, in rootURL: URL, fileExtension: String = "png") throws -> URL {
        try ensureLibraryStructure(at: rootURL)
        let fileName = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let imageURL = rootURL
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(fileName)
        try data.write(to: imageURL, options: [.atomic])
        return imageURL
    }

    func importPDF(
        at sourceURL: URL,
        in rootURL: URL,
        companionDirectoryRelativePath: String? = nil
    ) throws -> TickerImportedPDF {
        try ensureLibraryStructure(at: rootURL)

        let pdfID = UUID()
        let destinationURL = importedPDFURL(for: pdfID, in: rootURL)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        do {
            let fingerprint = try computePDFFingerprint(at: destinationURL)
            try savePDFMetadata(pdfID: pdfID, fingerprint: fingerprint, in: rootURL)

            let title = sourceURL.deletingPathExtension().lastPathComponent
            let note = try createNote(
                in: rootURL,
                title: title.isEmpty ? "Imported PDF" : title,
                kind: .pdfNote,
                tickerPDFID: pdfID,
                directoryRelativePath: companionDirectoryRelativePath
            )

            return TickerImportedPDF(
                pdfID: pdfID,
                sourceURL: sourceURL,
                importedURL: destinationURL,
                note: note
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            try? fileManager.removeItem(at: pdfMetadataURL(for: pdfID, in: rootURL))
            throw error
        }
    }

    func importedPDFURL(for pdfID: UUID, in rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("PDFs", isDirectory: true)
            .appendingPathComponent("\(pdfID.uuidString.lowercased()).pdf")
    }

    func computePDFFingerprint(at pdfURL: URL) throws -> TickerPDFFingerprint {
        let fileData = try Data(contentsOf: pdfURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: fileData)
        let sha256Hex = digest.map { String(format: "%02x", $0) }.joined()

        let resourceValues = try pdfURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(resourceValues.fileSize ?? fileData.count)
        let modificationTimestamp = (resourceValues.contentModificationDate ?? Date.distantPast).timeIntervalSince1970

        return TickerPDFFingerprint(
            fileSize: fileSize,
            modificationTimestamp: modificationTimestamp,
            sha256Hex: sha256Hex
        )
    }

    func savePDFMetadata(
        pdfID: UUID,
        fingerprint: TickerPDFFingerprint,
        in rootURL: URL
    ) throws {
        let existingHighlights = try loadPDFMetadata(pdfID: pdfID, in: rootURL)?.highlights ?? []
        let metadata = TickerPDFMetadata(
            schemaVersion: 1,
            pdfID: pdfID,
            fingerprint: fingerprint,
            highlights: existingHighlights,
            updatedAt: Date()
        )
        try writePDFMetadata(metadata, in: rootURL)
    }

    func appendPDFHighlight(
        pdfID: UUID,
        highlight: TickerPDFHighlightAnchor,
        in rootURL: URL
    ) throws {
        var metadata: TickerPDFMetadata
        if let existing = try loadPDFMetadata(pdfID: pdfID, in: rootURL) {
            metadata = existing
        } else {
            let pdfURL = importedPDFURL(for: pdfID, in: rootURL)
            let fingerprint = try computePDFFingerprint(at: pdfURL)
            metadata = TickerPDFMetadata(
                schemaVersion: 1,
                pdfID: pdfID,
                fingerprint: fingerprint,
                highlights: [],
                updatedAt: Date()
            )
        }

        metadata.highlights.removeAll { $0.id == highlight.id }
        metadata.highlights.append(highlight)
        metadata.highlights.sort { $0.createdAt < $1.createdAt }
        metadata.updatedAt = Date()

        try writePDFMetadata(metadata, in: rootURL)
    }

    func loadPDFHighlight(
        pdfID: UUID,
        highlightID: UUID,
        in rootURL: URL
    ) throws -> TickerPDFHighlightAnchor? {
        guard let metadata = try loadPDFMetadata(pdfID: pdfID, in: rootURL) else {
            return nil
        }
        return metadata.highlights.first { $0.id == highlightID }
    }

    func loadPDFHighlights(
        pdfID: UUID,
        in rootURL: URL
    ) throws -> [TickerPDFHighlightAnchor] {
        guard let metadata = try loadPDFMetadata(pdfID: pdfID, in: rootURL) else {
            return []
        }
        return metadata.highlights
    }

    private func writePDFMetadata(_ metadata: TickerPDFMetadata, in rootURL: URL) throws {
        let metadataURL = pdfMetadataURL(for: metadata.pdfID, in: rootURL)
        try fileManager.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])
    }

    func loadPDFMetadata(pdfID: UUID, in rootURL: URL) throws -> TickerPDFMetadata? {
        let metadataURL = pdfMetadataURL(for: pdfID, in: rootURL)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TickerPDFMetadata.self, from: data)
    }

    func inspectPDFDrift(
        for pdfID: UUID,
        in rootURL: URL
    ) throws -> TickerPDFDriftStatus {
        let importedURL = importedPDFURL(for: pdfID, in: rootURL)
        guard fileManager.fileExists(atPath: importedURL.path) else {
            return .missingFile
        }

        let currentFingerprint = try computePDFFingerprint(at: importedURL)
        guard let metadata = try loadPDFMetadata(pdfID: pdfID, in: rootURL) else {
            return .missingMetadata(current: currentFingerprint)
        }

        if metadata.fingerprint == currentFingerprint {
            return .matches
        }

        return .drifted(expected: metadata.fingerprint, current: currentFingerprint)
    }

    private func pdfMetadataURL(for pdfID: UUID, in rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("pdfs", isDirectory: true)
            .appendingPathComponent("\(pdfID.uuidString.lowercased()).json")
    }

    func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var sharedPrefixCount = 0
        while sharedPrefixCount < baseComponents.count &&
                sharedPrefixCount < targetComponents.count &&
                baseComponents[sharedPrefixCount] == targetComponents[sharedPrefixCount] {
            sharedPrefixCount += 1
        }

        let upwardTraversal = Array(repeating: "..", count: baseComponents.count - sharedPrefixCount)
        let targetRemainder = Array(targetComponents.dropFirst(sharedPrefixCount))
        let relativeComponents = upwardTraversal + targetRemainder

        if relativeComponents.isEmpty {
            return "."
        }
        return relativeComponents.joined(separator: "/")
    }

    func createNote(
        in rootURL: URL,
        title: String,
        kind: TickerNoteKind = .note,
        tickerPDFID: UUID? = nil,
        directoryRelativePath: String? = nil
    ) throws -> TickerMarkdownNote {
        try ensureLibraryStructure(at: rootURL)

        let parentDirectoryURL: URL
        if let directoryRelativePath, !directoryRelativePath.isEmpty {
            parentDirectoryURL = rootURL.appendingPathComponent(directoryRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
        } else {
            parentDirectoryURL = rootURL
        }

        let noteURL = uniqueMarkdownURL(forTitle: title, in: parentDirectoryURL)
        let frontMatter = TickerNoteFrontMatter(
            tickerID: UUID(),
            tickerKind: kind,
            tickerPDFID: tickerPDFID,
            createdAt: Date()
        )
        let markdown = TickerMarkdownFrontMatterCodec.serialize(frontMatter: frontMatter, body: "")
        try markdown.write(to: noteURL, atomically: true, encoding: .utf8)

        return TickerMarkdownNote(url: noteURL, frontMatter: frontMatter, body: "")
    }

    func loadNote(at noteURL: URL) throws -> TickerMarkdownNote {
        let markdown = try String(contentsOf: noteURL, encoding: .utf8)
        let parsed = TickerMarkdownFrontMatterCodec.parse(markdown)

        let frontMatter = parsed.frontMatter ?? TickerNoteFrontMatter(
            tickerID: UUID(),
            tickerKind: .note,
            tickerPDFID: nil,
            createdAt: Date()
        )

        return TickerMarkdownNote(url: noteURL, frontMatter: frontMatter, body: parsed.body)
    }

    func saveNote(_ note: TickerMarkdownNote) throws {
        let markdown = TickerMarkdownFrontMatterCodec.serialize(
            frontMatter: note.frontMatter,
            body: note.body
        )
        try markdown.write(to: note.url, atomically: true, encoding: .utf8)
    }

    func markdownFileURLs(in rootURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var markdownURLs: [URL] = []

        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            markdownURLs.append(url)
        }

        return markdownURLs.sorted { $0.path < $1.path }
    }

    func scanMarkdownNotes(in rootURL: URL) throws -> [TickerMarkdownNote] {
        let urls = try markdownFileURLs(in: rootURL)
        var notes: [TickerMarkdownNote] = []

        for url in urls {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let parsed = TickerMarkdownFrontMatterCodec.parse(markdown)
            guard let frontMatter = parsed.frontMatter else { continue }
            notes.append(
                TickerMarkdownNote(
                    url: url,
                    frontMatter: frontMatter,
                    body: parsed.body
                )
            )
        }

        return notes
    }

    func detectDuplicateTickerIDs(in rootURL: URL) throws -> [DuplicateTickerIDGroup] {
        let notes = try scanMarkdownNotes(in: rootURL)
        return TickerNoteDuplicateResolver.detectDuplicateTickerIDs(in: notes)
    }

    @discardableResult
    func fixDuplicateTickerIDs(in rootURL: URL) throws -> DuplicateTickerIDFixResult {
        let notes = try scanMarkdownNotes(in: rootURL)
        return try TickerNoteDuplicateResolver.fixDuplicateTickerIDs(in: notes)
    }

    private func uniqueMarkdownURL(forTitle title: String, in directoryURL: URL) -> URL {
        let baseSlug = slugify(title)
        var index = 1

        while true {
            let fileName: String
            if index == 1 {
                fileName = "\(baseSlug).md"
            } else {
                fileName = "\(baseSlug)-\(index).md"
            }

            let candidateURL = directoryURL.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func slugify(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let mapped = lowercased.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return slug.isEmpty ? "untitled" : slug
    }
}
