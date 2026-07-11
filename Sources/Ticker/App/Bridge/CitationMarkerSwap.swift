import Foundation

enum CitationMarkerRenderMode {
    case markdownLink
    case plainLabel
}

enum CitationMarkerSwap {
    // Some providers occasionally close an otherwise valid marker with `}`.
    // Accept that observed typo so raw citation syntax never leaks into notes.
    private static let markerPattern = #"【(\d+)(?:\|(["“”][^】【]*?["“”]|[^】}]*))?[】}]"#
    private static let quoteDelimiters: Set<Character> = ["\"", "“", "”"]
    private static let maxQuoteQueryLength = 200

    static func swap(_ text: String, manifest: [DocumentAICitationManifestEntry], mode: CitationMarkerRenderMode) -> String {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return text }

        var byNumber: [Int: DocumentAICitationManifestEntry] = [:]
        manifest.forEach { byNumber[$0.n] = $0 }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var output = ""
        var lastLocation = 0
        var previousChunkId: UUID?

        for match in matches {
            let markerRange = match.range(at: 0)
            let betweenRange = NSRange(location: lastLocation, length: markerRange.location - lastLocation)
            let between = nsText.substring(with: betweenRange)
            let markerNumber = Int(nsText.substring(with: match.range(at: 1))) ?? 0

            guard let entry = byNumber[markerNumber] else {
                output += between
                previousChunkId = nil
                lastLocation = markerRange.location + markerRange.length
                continue
            }

            let isAdjacentDuplicate = previousChunkId == entry.chunkId && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isAdjacentDuplicate {
                output += between
                let rawQuote = match.range(at: 2).location == NSNotFound ? nil : nsText.substring(with: match.range(at: 2))
                output = appendWithSpacing(output, renderedCitation(entry, quote: quote(from: rawQuote), mode: mode))
                previousChunkId = entry.chunkId
            }

            lastLocation = markerRange.location + markerRange.length
        }

        output += nsText.substring(from: lastLocation)
        return output
    }

    private static func renderedCitation(
        _ entry: DocumentAICitationManifestEntry,
        quote: String?,
        mode: CitationMarkerRenderMode
    ) -> String {
        let label = "\(entry.shortTitle) p.\(max(1, entry.page))"
        switch mode {
        case .plainLabel:
            return "(\(label))"
        case .markdownLink:
            return "[\(escapeMarkdownLabel(label))](\(tickerPDFURL(entry, quote: quote)))"
        }
    }

    private static func tickerPDFURL(_ entry: DocumentAICitationManifestEntry, quote: String?) -> String {
        var components = URLComponents()
        components.scheme = "ticker-pdf"
        components.host = entry.sourceId.uuidString
        var queryItems = [
            URLQueryItem(name: "page", value: "\(max(1, entry.page))"),
            URLQueryItem(name: "chunk", value: entry.chunkId.uuidString)
        ]
        if let quote = quote?.prefix(maxQuoteQueryLength), !quote.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: String(quote)))
        }
        components.queryItems = queryItems
        return components.string ?? "ticker-pdf://\(entry.sourceId.uuidString)"
    }

    private static func quote(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              quoteDelimiters.contains(first),
              quoteDelimiters.contains(last) else {
            return nil
        }

        let quote = String(trimmed.dropFirst().dropLast())
        return quote.isEmpty ? nil : quote
    }

    private static func appendWithSpacing(_ output: String, _ citation: String) -> String {
        guard !output.isEmpty else { return citation }

        if let range = output.range(of: #"[^\S\r\n]+$"#, options: .regularExpression) {
            let beforeWhitespace = String(output[..<range.lowerBound])
            if beforeWhitespace.isEmpty || beforeWhitespace.last?.isNewline == true {
                return beforeWhitespace + citation
            }
            return beforeWhitespace + " " + citation
        }

        if output.last?.isWhitespace == true {
            return output + citation
        }
        return output + " " + citation
    }

    static func escapeMarkdownLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
