import Foundation
import PDFKit

/// Builds local source chunks for Reading with Receipts indexing.
final class ChunkingService {
    struct Config {
        var targetTokens: Int = 800
        var overlapTokens: Int = 100
        var charsPerToken: Double = 4.0
    }

    private struct PageText {
        let page: Int
        let text: String
    }

    private struct SectionRange {
        let pageStart: Int
        let pageEnd: Int
        let path: String?
    }

    private struct OutlineEntry {
        let page: Int
        let depth: Int
        let path: String
    }

    private struct TextSegment {
        let text: String
        let page: Int
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func chunkPDF(
        document: PDFDocument,
        sourceId: UUID,
        progress: ((Double) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> [SourceChunk] {
        guard document.pageCount > 0 else { return [] }

        var pagesByNumber: [Int: PageText] = [:]
        for index in 0..<document.pageCount {
            if shouldCancel() {
                throw CancellationError()
            }

            if let page = document.page(at: index),
               let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                pagesByNumber[index + 1] = PageText(page: index + 1, text: text)
            }

            progress?(Double(index + 1) / Double(document.pageCount))
        }

        guard !pagesByNumber.isEmpty else { return [] }

        let sections = sectionRanges(for: document)
        let ranges = sections.isEmpty
            ? [SectionRange(pageStart: 1, pageEnd: document.pageCount, path: nil)]
            : sections

        var chunks: [SourceChunk] = []
        for range in ranges {
            if shouldCancel() {
                throw CancellationError()
            }

            let pageTexts = (range.pageStart...range.pageEnd)
                .compactMap { pagesByNumber[$0] }
            guard !pageTexts.isEmpty else { continue }

            chunks.append(contentsOf: chunkPages(
                pageTexts,
                sourceId: sourceId,
                sectionPath: range.path,
                startingSeq: chunks.count
            ))
        }

        return chunks
    }

    private func sectionRanges(for document: PDFDocument) -> [SectionRange] {
        guard let outlineRoot = document.outlineRoot else { return [] }

        var entries: [OutlineEntry] = []
        collectOutlineEntries(
            from: outlineRoot,
            document: document,
            parentPath: [],
            depth: 0,
            entries: &entries
        )

        entries.sort {
            if $0.page == $1.page { return $0.depth < $1.depth }
            return $0.page < $1.page
        }

        guard !entries.isEmpty else { return [] }

        var ranges: [SectionRange] = []
        var entryIndex = 0
        var activePath: String?
        var currentStart: Int?

        for page in 1...document.pageCount {
            var pathChanged = false
            while entryIndex < entries.count, entries[entryIndex].page <= page {
                let nextPath = entries[entryIndex].path
                if nextPath != activePath {
                    pathChanged = true
                    activePath = nextPath
                }
                entryIndex += 1
            }

            if currentStart == nil {
                currentStart = page
                continue
            }

            if pathChanged, let start = currentStart {
                ranges.append(SectionRange(pageStart: start, pageEnd: max(start, page - 1), path: activePathForPreviousPage(entries: entries, page: page - 1)))
                currentStart = page
            }
        }

        if let start = currentStart {
            ranges.append(SectionRange(pageStart: start, pageEnd: document.pageCount, path: activePath))
        }

        return ranges.filter { $0.path != nil }
    }

    private func activePathForPreviousPage(entries: [OutlineEntry], page: Int) -> String? {
        entries.last { $0.page <= page }?.path
    }

    private func collectOutlineEntries(
        from outline: PDFOutline,
        document: PDFDocument,
        parentPath: [String],
        depth: Int,
        entries: inout [OutlineEntry]
    ) {
        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }

            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = label.isEmpty ? parentPath : parentPath + [label]

            if let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound, !path.isEmpty {
                    entries.append(OutlineEntry(
                        page: pageIndex + 1,
                        depth: depth,
                        path: path.joined(separator: " > ")
                    ))
                }
            }

            collectOutlineEntries(
                from: child,
                document: document,
                parentPath: path,
                depth: depth + 1,
                entries: &entries
            )
        }
    }

    private func chunkPages(
        _ pageTexts: [PageText],
        sourceId: UUID,
        sectionPath: String?,
        startingSeq: Int
    ) -> [SourceChunk] {
        let segments = pageTexts.flatMap { pageText in
            splitIntoSentenceSegments(pageText.text, page: pageText.page)
        }
        guard !segments.isEmpty else { return [] }

        var chunks: [SourceChunk] = []
        var current: [TextSegment] = []
        var currentTokens = 0

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(makeChunk(
                from: current,
                sourceId: sourceId,
                seq: startingSeq + chunks.count,
                sectionPath: sectionPath
            ))
            current = overlapSegments(from: current)
            currentTokens = current.reduce(0) { $0 + estimateTokens($1.text) }
        }

        for segment in segments {
            let parts = splitLongSegmentIfNeeded(segment)
            for part in parts {
                let tokens = estimateTokens(part.text)
                if currentTokens > 0, currentTokens + tokens > config.targetTokens {
                    flushCurrent()
                }
                current.append(part)
                currentTokens += tokens
            }
        }

        if !current.isEmpty {
            chunks.append(makeChunk(
                from: current,
                sourceId: sourceId,
                seq: startingSeq + chunks.count,
                sectionPath: sectionPath
            ))
        }

        return chunks
    }

    private func makeChunk(
        from segments: [TextSegment],
        sourceId: UUID,
        seq: Int,
        sectionPath: String?
    ) -> SourceChunk {
        let text = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceChunk(
            sourceId: sourceId,
            seq: seq,
            text: text,
            pageStart: segments.first?.page ?? 1,
            pageEnd: segments.last?.page ?? segments.first?.page ?? 1,
            sectionPath: sectionPath
        )
    }

    private func splitIntoSentenceSegments(_ text: String, page: Int) -> [TextSegment] {
        var segments: [TextSegment] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else { return }
            segments.append(TextSegment(text: sentence, page: page))
        }

        if !segments.isEmpty { return segments }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { TextSegment(text: $0, page: page) }
    }

    private func splitLongSegmentIfNeeded(_ segment: TextSegment) -> [TextSegment] {
        guard estimateTokens(segment.text) > config.targetTokens else {
            return [segment]
        }

        let targetChars = max(1, Int(Double(config.targetTokens) * config.charsPerToken))
        var parts: [TextSegment] = []
        var remaining = segment.text[...]

        while !remaining.isEmpty {
            if remaining.count <= targetChars {
                parts.append(TextSegment(text: String(remaining).trimmingCharacters(in: .whitespacesAndNewlines), page: segment.page))
                break
            }

            let tentativeEnd = remaining.index(remaining.startIndex, offsetBy: targetChars)
            let prefix = remaining[..<tentativeEnd]
            let breakIndex = prefix.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? tentativeEnd
            let part = remaining[..<breakIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty {
                parts.append(TextSegment(text: String(part), page: segment.page))
            }
            remaining = remaining[breakIndex...].trimmingCharacters(in: .whitespacesAndNewlines)[...]
        }

        return parts
    }

    private func overlapSegments(from segments: [TextSegment]) -> [TextSegment] {
        var result: [TextSegment] = []
        var tokens = 0

        for segment in segments.reversed() {
            let segmentTokens = estimateTokens(segment.text)
            if !result.isEmpty, tokens + segmentTokens > config.overlapTokens {
                break
            }
            result.append(segment)
            tokens += segmentTokens
        }

        return result.reversed()
    }

    private func estimateTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / config.charsPerToken)))
    }
}
