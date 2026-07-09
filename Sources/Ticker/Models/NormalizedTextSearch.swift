import Foundation

struct NormalizedTextMap {
    struct OriginalSpan {
        let start: String.Index
        let end: String.Index
    }

    let normalized: String
    let originalSpans: [OriginalSpan]

    static func build(from text: String) -> NormalizedTextMap {
        var normalized = ""
        var originalSpans: [OriginalSpan] = []
        var pendingWhitespaceStart: String.Index?
        var pendingWhitespaceEnd: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let nextIndex = text.index(after: index)
            let character = text[index]

            if normalizedReplacement(for: character).isEmpty {
                index = nextIndex
                continue
            }

            if isWhitespace(character) {
                if !normalized.isEmpty {
                    pendingWhitespaceStart = pendingWhitespaceStart ?? index
                    pendingWhitespaceEnd = nextIndex
                }
                index = nextIndex
                continue
            }

            if let whitespaceStart = pendingWhitespaceStart,
               let whitespaceEnd = pendingWhitespaceEnd {
                normalized.append(" ")
                originalSpans.append(OriginalSpan(start: whitespaceStart, end: whitespaceEnd))
                pendingWhitespaceStart = nil
                pendingWhitespaceEnd = nil
            }

            for normalizedCharacter in normalizedReplacement(for: character) {
                normalized.append(normalizedCharacter)
                originalSpans.append(OriginalSpan(start: index, end: nextIndex))
            }
            index = nextIndex
        }

        return NormalizedTextMap(normalized: normalized, originalSpans: originalSpans)
    }

    func originalRange(for normalizedRange: Range<String.Index>) -> Range<String.Index>? {
        let lowerOffset = normalized.distance(from: normalized.startIndex, to: normalizedRange.lowerBound)
        let upperOffset = normalized.distance(from: normalized.startIndex, to: normalizedRange.upperBound)
        guard lowerOffset >= 0,
              upperOffset > lowerOffset,
              lowerOffset < originalSpans.count,
              upperOffset <= originalSpans.count else {
            return nil
        }

        return originalSpans[lowerOffset].start..<originalSpans[upperOffset - 1].end
    }

    private static func normalizedReplacement(for character: Character) -> String {
        String(character)
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }
}

enum NormalizedTextSearch {
    static func range(of needle: String, in haystack: String) -> Range<String.Index>? {
        let needleMap = NormalizedTextMap.build(from: needle)
        guard !needleMap.normalized.isEmpty else { return nil }

        let haystackMap = NormalizedTextMap.build(from: haystack)
        guard let normalizedRange = haystackMap.normalized.range(of: needleMap.normalized) else {
            return nil
        }
        return haystackMap.originalRange(for: normalizedRange)
    }

    static func utf16Range(of needle: String, in haystack: String) -> Range<Int>? {
        guard let range = range(of: needle, in: haystack),
              let lower = range.lowerBound.samePosition(in: haystack.utf16),
              let upper = range.upperBound.samePosition(in: haystack.utf16) else {
            return nil
        }
        let start = haystack.utf16.distance(from: haystack.utf16.startIndex, to: lower)
        let end = haystack.utf16.distance(from: haystack.utf16.startIndex, to: upper)
        return start..<end
    }
}
