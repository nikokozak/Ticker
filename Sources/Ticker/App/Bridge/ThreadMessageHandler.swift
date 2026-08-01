import Foundation

@MainActor
final class ThreadMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "addStreamThreadAnchor",
        "listConversations",
        "createStreamThread",
        "deleteStreamThread",
        "loadStreamThread",
        "removeStreamThreadAnchor",
        "saveStreamThread"
    ]

    private let persistence: PersistenceService
    private let sendToWeb: (BridgeMessage) -> Void
    private let sendBridgeError: (String, String) -> Void

    init?(container: ServiceContainer) {
        guard let persistence = container.persistence else { return nil }
        self.persistence = persistence
        self.sendToWeb = { [bridgeService = container.bridgeService] message in
            bridgeService.send(message)
        }
        self.sendBridgeError = { [bridgeService = container.bridgeService] type, reason in
            bridgeService.sendBridgeError(type: type, reason: reason)
        }
    }

    init(
        persistence: PersistenceService,
        sendToWeb: @escaping (BridgeMessage) -> Void,
        sendBridgeError: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.persistence = persistence
        self.sendToWeb = sendToWeb
        self.sendBridgeError = sendBridgeError
    }

    func handle(_ message: BridgeMessage) async {
        guard let callbackId = message.callbackId else {
            sendBridgeError(message.type, "Missing callbackId for \(message.type)")
            return
        }
        switch message.type {
        case "listConversations":
            guard let streamId = decodeUUID(message.payload, key: "streamId") else {
                respondWithError(callbackId, "Invalid listConversations payload")
                return
            }
            do {
                respond(callbackId, [
                    "conversations": AnyCodable(StreamCodec.encodeConversationAnchors(
                        try persistence.loadConversationAnchors(streamId: streamId)
                    ))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "createStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let title = payload["title"]?.value as? String,
                  let anchorText = payload["anchorText"]?.value as? String,
                  !anchorText.isEmpty,
                  let anchorStart = payload["anchorStart"]?.intValue,
                  let anchorEnd = payload["anchorEnd"]?.intValue,
                  anchorStart >= 0,
                  anchorEnd > anchorStart,
                  let references = Self.decodePrimaryPDFReferences(payload) else {
                respondWithError(callbackId, "Invalid createStreamThread payload")
                return
            }
            do {
                let thread = try persistence.createStreamThread(StreamThread(
                    streamId: streamId,
                    title: title,
                    anchorText: anchorText,
                    sourceId: references.sourceId,
                    highlightId: references.highlightId,
                    anchorStart: anchorStart,
                    anchorEnd: anchorEnd
                ))
                respond(callbackId, [
                    "thread": AnyCodable(try encodeThread(thread))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "loadStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId") else {
                respondWithError(callbackId, "Invalid loadStreamThread payload")
                return
            }
            do {
                guard let thread = try persistence.loadStreamThread(
                    threadId: threadId,
                    streamId: streamId
                ) else {
                    throw StreamThreadPersistenceError.threadNotFound
                }
                respond(callbackId, [
                    "thread": AnyCodable(try encodeThread(thread))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "addStreamThreadAnchor":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId") else {
                respondWithError(callbackId, "Invalid addStreamThreadAnchor payload")
                return
            }
            do {
                let decoded = try decodeAnchors(payload["anchors"]?.value, threadId: threadId)
                guard decoded.anchors.count == 1, decoded.highlights.count <= 1 else {
                    throw StreamThreadPersistenceError.invalidAnchor
                }
                let anchor = try persistence.addStreamThreadAnchor(
                    decoded.anchors[0],
                    streamId: streamId,
                    pdfHighlight: decoded.highlights.first
                )
                respond(callbackId, ["anchor": AnyCodable(try encodeAnchor(anchor))])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "removeStreamThreadAnchor":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId"),
                  let anchorId = payload["anchorId"]?.value as? String,
                  !anchorId.isEmpty else {
                respondWithError(callbackId, "Invalid removeStreamThreadAnchor payload")
                return
            }
            do {
                respond(callbackId, ["removed": AnyCodable(try persistence.removeStreamThreadAnchor(
                    anchorId: anchorId,
                    threadId: threadId,
                    streamId: streamId
                ))])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "deleteStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId") else {
                respondWithError(callbackId, "Invalid deleteStreamThread payload")
                return
            }
            do {
                let highlightIds = try persistence.deleteStreamThread(
                    threadId: threadId,
                    streamId: streamId
                )
                respond(callbackId, [
                    "highlightIds": AnyCodable(highlightIds.map(\.uuidString))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "saveStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId"),
                  let title = payload["title"]?.value as? String,
                  let baseRevision = payload["baseRevision"]?.intValue,
                  baseRevision >= 0 else {
                respondWithError(callbackId, "Invalid saveStreamThread payload")
                return
            }
            do {
                let thread = try persistence.saveStreamThread(
                    threadId: threadId,
                    streamId: streamId,
                    title: title,
                    baseRevision: baseRevision
                )
                respond(callbackId, [
                    "conflict": AnyCodable(false),
                    "thread": AnyCodable(try encodeThread(thread))
                ])
            } catch let conflict as StreamThreadRevisionConflict {
                do {
                    respond(callbackId, [
                        "conflict": AnyCodable(true),
                        "thread": AnyCodable(try encodeThread(conflict.current))
                    ])
                } catch {
                    respondWithError(callbackId, error.localizedDescription)
                }
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        default:
            sendBridgeError(message.type, "Unsupported thread message")
        }
    }

    private func encodeThread(_ thread: StreamThread) throws -> [String: Any] {
        let source = try thread.sourceId.flatMap { try persistence.loadSource(id: $0) }
        let highlight = try source.flatMap { source in
            try thread.highlightId.flatMap {
                try persistence.loadPDFHighlight(id: $0, sourceId: source.id)
            }
        }
        let exchanges = try persistence.loadThreadExchanges(
            threadId: thread.threadId,
            streamId: thread.streamId
        )
        let anchors = try persistence.loadStreamThreadAnchors(
            threadId: thread.threadId,
            streamId: thread.streamId
        ).map { anchor in
            let anchorSource = try anchor.sourceId.flatMap { try persistence.loadSource(id: $0) }
            let anchorHighlight = try anchorSource.flatMap { source in
                try anchor.highlightId.flatMap {
                    try persistence.loadPDFHighlight(id: $0, sourceId: source.id)
                }
            }
            return StreamCodec.encodeThreadAnchor(anchor, source: anchorSource, highlight: anchorHighlight)
        }
        return StreamCodec.encodeThread(
            thread,
            source: source,
            highlight: highlight,
            exchanges: exchanges,
            anchors: anchors
        )
    }

    private func encodeAnchor(_ anchor: StreamThreadAnchor) throws -> [String: Any] {
        let source = try anchor.sourceId.flatMap { try persistence.loadSource(id: $0) }
        let highlight = try source.flatMap { source in
            try anchor.highlightId.flatMap {
                try persistence.loadPDFHighlight(id: $0, sourceId: source.id)
            }
        }
        return StreamCodec.encodeThreadAnchor(anchor, source: source, highlight: highlight)
    }

    private func decodeAnchors(
        _ value: Any?,
        threadId: UUID
    ) throws -> (anchors: [StreamThreadAnchor], highlights: [PDFHighlightRecord]) {
        guard let items = value as? [[String: Any]] else {
            throw StreamThreadPersistenceError.invalidAnchor
        }
        var anchors: [StreamThreadAnchor] = []
        var highlights: [PDFHighlightRecord] = []
        for item in items {
            guard let anchorId = item["anchorId"] as? String,
                  !anchorId.isEmpty,
                  let kindRaw = item["kind"] as? String,
                  let kind = StreamThreadAnchorKind(rawValue: kindRaw),
                  let quote = Self.optionalString(item["quote"]) else {
                throw StreamThreadPersistenceError.invalidAnchor
            }
            let createdAt = Self.dateValue(item["createdAt"]) ?? Date()
            let anchorSpanId = Self.optionalString(item["anchorSpanId"])
            let sourceId = Self.optionalString(item["sourceId"]).flatMap(UUID.init(uuidString:))
            let highlightId = Self.optionalString(item["highlightId"]).flatMap(UUID.init(uuidString:))
            anchors.append(StreamThreadAnchor(
                anchorId: anchorId,
                threadId: threadId,
                kind: kind,
                quote: quote,
                anchorSpanId: anchorSpanId,
                sourceId: sourceId,
                highlightId: highlightId,
                createdAt: createdAt
            ))

            guard kind == .pdfQuote,
                  let sourceId,
                  let highlightId,
                  let rectItems = item["rects"] as? [[String: Any]],
                  !rectItems.isEmpty else { continue }
            let rects = try rectItems.map { rect -> PDFHighlightRect in
                guard let page = Self.intValue(rect["page"]),
                      let x = Self.doubleValue(rect["x"]),
                      let y = Self.doubleValue(rect["y"]),
                      let w = Self.doubleValue(rect["w"]),
                      let h = Self.doubleValue(rect["h"]),
                      page > 0, w > 0, h > 0 else {
                    throw StreamThreadPersistenceError.invalidAnchor
                }
                return PDFHighlightRect(page: page, x: x, y: y, w: w, h: h)
            }
            highlights.append(PDFHighlightRecord(
                id: highlightId,
                sourceId: sourceId,
                page: rects[0].page,
                rects: rects,
                quote: quote,
                createdAt: createdAt
            ))
        }
        return (anchors, highlights)
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func decodePrimaryPDFReferences(
        _ payload: [String: AnyCodable]
    ) -> (sourceId: UUID?, highlightId: UUID?)? {
        let source = payload["sourceId"]?.value as? String
        let highlight = payload["highlightId"]?.value as? String
        guard (source == nil) == (highlight == nil) else { return nil }
        guard let source, let highlight else { return (nil, nil) }
        guard let sourceId = UUID(uuidString: source),
              let highlightId = UUID(uuidString: highlight) else { return nil }
        return (sourceId, highlightId)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.rounded(.towardZero) == value { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let raw = value as? String { return ISO8601DateFormatter().date(from: raw) }
        if let seconds = doubleValue(value) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    private func respond(_ callbackId: String, _ payload: [String: AnyCodable]) {
        sendToWeb(BridgeMessage(type: "callback", payload: payload, callbackId: callbackId))
    }

    private func respondWithError(_ callbackId: String, _ error: String) {
        respond(callbackId, ["error": AnyCodable(error)])
    }

    private func decodeUUID(_ payload: [String: AnyCodable]?, key: String) -> UUID? {
        guard let raw = payload?[key]?.value as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
