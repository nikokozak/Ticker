import Foundation

struct TickerPDFDestination: Equatable {
    let sourceId: UUID?
    let highlightId: String?
    let page: Int?
    let chunkId: UUID?
}

enum TickerPDFURLParser {
    static func parse(_ rawURL: String) -> TickerPDFDestination? {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.caseInsensitiveCompare("ticker-pdf") == .orderedSame else {
            return nil
        }

        let host = components.host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isEmpty else {
            return nil
        }

        let highlightId = queryValue("highlight", in: components)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let page = queryValue("page", in: components).flatMap(Self.parsePage)
        let chunkId = queryValue("chunk", in: components).flatMap(UUID.init(uuidString:))

        if highlightId != nil || page != nil || chunkId != nil {
            guard let sourceId = UUID(uuidString: host) else {
                return nil
            }
            return TickerPDFDestination(
                sourceId: sourceId,
                highlightId: highlightId,
                page: page,
                chunkId: chunkId
            )
        }

        guard let legacyHighlightId = UUID(uuidString: host) else {
            return nil
        }

        return TickerPDFDestination(
            sourceId: nil,
            highlightId: legacyHighlightId.uuidString,
            page: nil,
            chunkId: nil
        )
    }

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static func parsePage(_ value: String) -> Int? {
        guard let page = Int(value), page > 0 else {
            return nil
        }
        return page
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
