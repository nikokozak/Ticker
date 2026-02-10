import Foundation

struct TickerNextAuthorshipSpan: Codable, Equatable {
    var startUTF16: Int
    var lengthUTF16: Int
    var source: String
    var createdAt: Date

    var endUTF16: Int {
        startUTF16 + lengthUTF16
    }

    private enum CodingKeys: String, CodingKey {
        case startUTF16 = "start_utf16"
        case lengthUTF16 = "length_utf16"
        case source
        case createdAt = "created_at"
    }
}

struct TickerNextTextEdit: Equatable {
    var replacedRange: NSRange
    var insertedLength: Int

    var delta: Int {
        insertedLength - replacedRange.length
    }
}

enum TickerNextTextEditDetector {
    static func detectSingleEdit(from oldText: String, to newText: String) -> TickerNextTextEdit? {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)

        let oldLength = oldUnits.count
        let newLength = newUnits.count
        let minimumLength = min(oldLength, newLength)

        var commonPrefix = 0
        while commonPrefix < minimumLength, oldUnits[commonPrefix] == newUnits[commonPrefix] {
            commonPrefix += 1
        }

        var commonSuffix = 0
        while commonSuffix < (oldLength - commonPrefix),
              commonSuffix < (newLength - commonPrefix),
              oldUnits[oldLength - 1 - commonSuffix] == newUnits[newLength - 1 - commonSuffix] {
            commonSuffix += 1
        }

        let replacedLength = oldLength - commonPrefix - commonSuffix
        let insertedLength = newLength - commonPrefix - commonSuffix

        guard replacedLength > 0 || insertedLength > 0 else {
            return nil
        }

        return TickerNextTextEdit(
            replacedRange: NSRange(location: commonPrefix, length: replacedLength),
            insertedLength: insertedLength
        )
    }
}

enum TickerNextAuthorshipSpanTransformer {
    static func applyUserEdit(
        spans: [TickerNextAuthorshipSpan],
        edit: TickerNextTextEdit
    ) -> [TickerNextAuthorshipSpan] {
        guard !spans.isEmpty else { return [] }

        let editStart = edit.replacedRange.location
        let editEnd = edit.replacedRange.location + edit.replacedRange.length

        var updated: [TickerNextAuthorshipSpan] = []
        updated.reserveCapacity(spans.count + 1)

        for span in spans {
            let spanStart = span.startUTF16
            let spanEnd = span.endUTF16

            if spanEnd <= editStart {
                updated.append(span)
                continue
            }

            if spanStart >= editEnd {
                var shifted = span
                shifted.startUTF16 += edit.delta
                updated.append(shifted)
                continue
            }

            let leftLength = max(0, editStart - spanStart)
            if leftLength > 0 {
                var left = span
                left.lengthUTF16 = leftLength
                updated.append(left)
            }

            let rightLength = max(0, spanEnd - editEnd)
            if rightLength > 0 {
                var right = span
                right.startUTF16 = edit.replacedRange.location + edit.insertedLength
                right.lengthUTF16 = rightLength
                updated.append(right)
            }
        }

        return normalize(updated)
    }

    static func addAIInsertion(
        range: NSRange,
        source: String,
        to spans: [TickerNextAuthorshipSpan],
        createdAt: Date = Date()
    ) -> [TickerNextAuthorshipSpan] {
        guard range.length > 0 else {
            return normalize(spans)
        }

        var updated = spans
        updated.append(
            TickerNextAuthorshipSpan(
                startUTF16: range.location,
                lengthUTF16: range.length,
                source: source,
                createdAt: createdAt
            )
        )

        return normalize(updated)
    }

    static func clamped(
        spans: [TickerNextAuthorshipSpan],
        toUTF16Length textLength: Int
    ) -> [TickerNextAuthorshipSpan] {
        guard textLength >= 0 else { return [] }

        let clampedSpans: [TickerNextAuthorshipSpan] = spans.compactMap { span in
            guard span.lengthUTF16 > 0, span.startUTF16 < textLength else {
                return nil
            }

            let clampedStart = max(0, span.startUTF16)
            let clampedEnd = min(textLength, span.endUTF16)
            guard clampedEnd > clampedStart else {
                return nil
            }

            var updated = span
            updated.startUTF16 = clampedStart
            updated.lengthUTF16 = clampedEnd - clampedStart
            return updated
        }

        return normalize(clampedSpans)
    }

    static func normalize(_ spans: [TickerNextAuthorshipSpan]) -> [TickerNextAuthorshipSpan] {
        let sorted = spans
            .filter { $0.lengthUTF16 > 0 }
            .sorted {
                if $0.startUTF16 == $1.startUTF16 {
                    return $0.endUTF16 < $1.endUTF16
                }
                return $0.startUTF16 < $1.startUTF16
            }

        guard !sorted.isEmpty else { return [] }

        var merged: [TickerNextAuthorshipSpan] = []
        merged.reserveCapacity(sorted.count)

        for span in sorted {
            guard var last = merged.last else {
                merged.append(span)
                continue
            }

            if span.startUTF16 <= last.endUTF16, span.source == last.source {
                let mergedEnd = max(last.endUTF16, span.endUTF16)
                last.lengthUTF16 = mergedEnd - last.startUTF16
                last.createdAt = min(last.createdAt, span.createdAt)
                merged[merged.count - 1] = last
                continue
            }

            merged.append(span)
        }

        return merged
    }
}

struct TickerNextDocMetadata: Codable, Equatable {
    var schemaVersion: Int
    var aiSpans: [TickerNextAuthorshipSpan]

    init(schemaVersion: Int = 1, aiSpans: [TickerNextAuthorshipSpan]) {
        self.schemaVersion = schemaVersion
        self.aiSpans = aiSpans
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case aiSpans = "ai_spans"
    }
}

final class TickerNextDocMetadataStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadSpans(
        for note: TickerMarkdownNote,
        libraryRootURL: URL
    ) throws -> [TickerNextAuthorshipSpan] {
        let metadataURL = metadataFileURL(for: note, libraryRootURL: libraryRootURL)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        let metadata = try decoder.decode(TickerNextDocMetadata.self, from: data)
        return TickerNextAuthorshipSpanTransformer.normalize(metadata.aiSpans)
    }

    func saveSpans(
        _ spans: [TickerNextAuthorshipSpan],
        for note: TickerMarkdownNote,
        libraryRootURL: URL
    ) throws {
        let metadataURL = metadataFileURL(for: note, libraryRootURL: libraryRootURL)
        let parentDirectory = metadataURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let metadata = TickerNextDocMetadata(
            schemaVersion: 1,
            aiSpans: TickerNextAuthorshipSpanTransformer.normalize(spans)
        )
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])
    }

    private func metadataFileURL(
        for note: TickerMarkdownNote,
        libraryRootURL: URL
    ) -> URL {
        libraryRootURL
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("\(note.frontMatter.tickerID.uuidString.lowercased()).json")
    }
}
