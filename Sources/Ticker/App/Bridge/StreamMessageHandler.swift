import AppKit
import Foundation

protocol StreamMessageHandlerDelegate: AnyObject {
    func setCurrentStreamIdForFileDrops(_ streamId: UUID?)
    func consumeLastOpenStreamIdForLaunchRestore() -> UUID?
    func clearCurrentStreamIdForFileDrops(ifMatches streamId: UUID)
    func closePDFPaneIfShowingDifferentStream(_ streamId: UUID) async
}

final class StreamMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "loadStreams",
        "loadStream",
        "createStream",
        "updateStreamTitle",
        "deleteStream",
        "saveRichStreamDocument",
        "saveStreamDocument",
        "saveScrollPosition",
        "setSourceScope",
        "updateMarginNote",
        "openExternalURL",
        "getExchange"
    ]

    private let persistence: PersistenceService
    private let bridgeService: BridgeService
    private let assetService: AssetService
    private let ingestService: IngestService?
    private let autoTitleService: AutoTitleService?
    private weak var delegate: StreamMessageHandlerDelegate?

    init?(container: ServiceContainer, delegate: StreamMessageHandlerDelegate) {
        guard let persistence = container.persistence else { return nil }
        self.persistence = persistence
        self.bridgeService = container.bridgeService
        self.assetService = container.assetService
        self.ingestService = container.ingestService
        self.autoTitleService = container.autoTitleService
        self.delegate = delegate
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "loadStreams":
            do {
                let summaries = try persistence.loadStreamSummaries()
                let payload = StreamCodec.encodeSummaries(summaries)
                await bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: [
                    "streams": payload["streams"]!
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to load streams (\(DebugLog.errorSummary(error)))")
                await bridgeService.send(BridgeMessage(
                    type: "streamsLoadFailed",
                    payload: ["reason": AnyCodable("unavailable")]
                ))
                return
            }

            if let restoreId = delegate?.consumeLastOpenStreamIdForLaunchRestore() {
                do {
                    try await sendStreamLoaded(id: restoreId)
                } catch {
                    DebugLog.log("[StreamMessageHandler] Failed to restore last stream (\(DebugLog.errorSummary(error)))")
                    await sendStreamLoadFailed(id: restoreId, requestId: nil, reason: "unavailable")
                }
            }

        case "loadStream":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue) else {
                DebugLog.log("[WebViewManager] Invalid loadStream payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid loadStream payload")
                return
            }
            do {
                try await sendStreamLoaded(id: id, requestId: payload["requestId"]?.intValue)
            } catch {
                DebugLog.log("[WebViewManager] Failed to load stream (\(DebugLog.errorSummary(error)))")
                await sendStreamLoadFailed(
                    id: id,
                    requestId: payload["requestId"]?.intValue,
                    reason: "unavailable"
                )
            }

        case "createStream":
            let title = (message.payload?["title"]?.value as? String) ?? "Untitled"
            do {
                let stream = try persistence.createStream(title: title)
                delegate?.setCurrentStreamIdForFileDrops(stream.id)
                let document = try persistence.loadOrCreateStreamDocument(streamId: stream.id)
                let streamPayload = StreamCodec.encodeStream(stream, document: document)
                let payload: [String: AnyCodable] = [
                    "stream": AnyCodable(streamPayload),
                    "sourceScope": AnyCodable(stream.sourceScope.rawValue),
                    "scrollOffset": AnyCodable(document.scrollOffset),
                    "spans": AnyCodable(StreamCodec.encodeSpans([])),
                    "pendingAppends": AnyCodable(StreamCodec.encodePendingAppends([])),
                    "appendInbox": AnyCodable(StreamCodec.encodeAppendInbox([])),
                    "marginNotes": AnyCodable([])
                ]
                await bridgeService.send(BridgeMessage(type: "streamLoaded", payload: payload))
            } catch {
                DebugLog.log("[WebViewManager] Failed to create stream (\(DebugLog.errorSummary(error)))")
            }

        case "updateStreamTitle":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue),
                  let title = payload["title"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid updateStreamTitle payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid updateStreamTitle payload")
                return
            }
            do {
                if try persistence.updateStreamTitle(id: id, title: title) {
                    await bridgeService.send(BridgeMessage(type: "streamTitleUpdated", payload: ["id": AnyCodable(id.uuidString), "title": AnyCodable(title)]))
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to update stream title (\(DebugLog.errorSummary(error)))")
            }

        case "deleteStream":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue) else {
                DebugLog.log("[WebViewManager] Invalid deleteStream payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid deleteStream payload")
                return
            }
            do {
                try persistence.deleteStream(id: id)
                delegate?.clearCurrentStreamIdForFileDrops(ifMatches: id)
                // Also delete stream assets (images, etc.)
                do {
                    try assetService.deleteAssets(for: id)
                } catch {
                    DebugLog.log("[StreamMessageHandler] Failed to delete stream assets (\(DebugLog.errorSummary(error)))")
                }
                // Reload streams list
                let summaries = try persistence.loadStreamSummaries()
                let summariesPayload = StreamCodec.encodeSummaries(summaries)
                await bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: [
                    "streams": summariesPayload["streams"]!
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to delete stream (\(DebugLog.errorSummary(error)))")
            }

        case "saveStreamDocument", "saveRichStreamDocument":
            guard let callbackId = message.callbackId else {
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for \(message.type)")
                return
            }
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let markdown = payload["markdown"]?.value as? String,
                  let baseRevision = payload["baseRevision"]?.intValue,
                  let spans = decodeSpans(payload["spans"]?.value, streamId: streamId) else {
                DebugLog.log("[WebViewManager] Invalid saveStreamDocument payload")
                await bridgeService.respondWithError(to: callbackId, error: "Invalid saveStreamDocument payload")
                return
            }
            let canonicalDocument: (json: String, version: Int)?
            if message.type == "saveRichStreamDocument" {
                guard let docJSON = payload["docJSON"]?.value as? String,
                      let docFormatVersion = payload["docFormatVersion"]?.intValue else {
                    await bridgeService.respondWithError(to: callbackId, error: "Invalid saveRichStreamDocument payload")
                    return
                }
                canonicalDocument = (docJSON, docFormatVersion)
            } else {
                canonicalDocument = nil
            }
            do {
                let revision: Int
                if let canonicalDocument {
                    revision = try persistence.saveStreamDocument(
                        streamId: streamId,
                        docJSON: canonicalDocument.json,
                        docFormatVersion: canonicalDocument.version,
                        markdown: markdown,
                        baseRevision: baseRevision,
                        spans: spans,
                        resolvedPendingThrough: payload["resolvedPendingThrough"]?.intValue,
                        consumedInboxThrough: payload["consumedInboxThrough"]?.intValue
                    )
                } else {
                    revision = try persistence.saveStreamDocument(
                        streamId: streamId,
                        markdown: markdown,
                        baseRevision: baseRevision,
                        spans: spans,
                        resolvedPendingThrough: payload["resolvedPendingThrough"]?.intValue
                    )
                }
                await bridgeService.respond(to: callbackId, with: [
                    "revision": AnyCodable(revision)
                ])
                if let autoTitleService {
                    Task {
                        await autoTitleService.scheduleIfNeeded(streamId: streamId, markdown: markdown)
                    }
                }
            } catch let conflict as StreamDocumentRevisionConflict {
                let pendingAppends = StreamCodec.encodePendingAppends(conflict.pendingAppends)
                let appendInbox = StreamCodec.encodeAppendInbox(conflict.appendInbox)
                var conflictPayload: [String: AnyCodable] = [
                    "streamId": AnyCodable(conflict.streamId.uuidString),
                    "markdown": AnyCodable(conflict.markdown),
                    "revision": AnyCodable(conflict.revision),
                    "spans": AnyCodable(StreamCodec.encodeSpans(conflict.spans)),
                    "pendingAppends": AnyCodable(pendingAppends),
                    "appendInbox": AnyCodable(appendInbox)
                ]
                if let docJSON = conflict.docJSON, let docFormatVersion = conflict.docFormatVersion {
                    conflictPayload["docJSON"] = AnyCodable(docJSON)
                    conflictPayload["docFormatVersion"] = AnyCodable(docFormatVersion)
                }
                await bridgeService.send(BridgeMessage(type: "streamDocumentConflict", payload: conflictPayload))
                await bridgeService.respondWithError(to: callbackId, error: "Stream document revision conflict")
            } catch {
                DebugLog.log("[WebViewManager] Failed to save stream document (\(DebugLog.errorSummary(error)))")
                await bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
            }

        case "saveScrollPosition":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let offset = payload["offset"]?.doubleValue else {
                DebugLog.log("[WebViewManager] Invalid saveScrollPosition payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid saveScrollPosition payload")
                return
            }
            do {
                try persistence.saveScrollOffset(streamId: streamId, offset: offset)
            } catch {
                DebugLog.log("[WebViewManager] Failed to save scroll position (\(DebugLog.errorSummary(error)))")
            }

        case "setSourceScope":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let scopeValue = payload["scope"]?.value as? String,
                  let scope = SourceScope(rawValue: scopeValue) else {
                DebugLog.log("[WebViewManager] Invalid setSourceScope payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid setSourceScope payload")
                return
            }
            do {
                _ = try persistence.setSourceScope(streamId: streamId, scope: scope)
            } catch {
                DebugLog.log("[WebViewManager] Failed to set source scope (\(DebugLog.errorSummary(error)))")
            }

        case "updateMarginNote":
            guard let payload = message.payload,
                  let noteId = payload["noteId"]?.value as? String,
                  let status = payload["status"]?.value as? String,
                  ["open", "dismissed", "promoted", "unanchored"].contains(status) else {
                DebugLog.log("[StreamMessageHandler] Invalid updateMarginNote payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid updateMarginNote payload")
                return
            }
            do {
                if let result = try persistence.updateMarginNoteStatusAndLoadVisible(noteId: noteId, status: status) {
                    await bridgeService.send(BridgeMessage(type: "marginNotesChanged", payload: [
                        "streamId": AnyCodable(result.streamId.uuidString),
                        "notes": AnyCodable(StreamCodec.encodeMarginNotes(result.notes))
                    ]))
                }
            } catch {
                DebugLog.log("[StreamMessageHandler] Failed to update margin note (\(DebugLog.errorSummary(error)))")
            }

        case "getExchange":
            guard let callbackId = message.callbackId else {
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for getExchange")
                return
            }
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid getExchange payload")
                await bridgeService.respondWithError(to: callbackId, error: "Invalid getExchange payload")
                return
            }
            do {
                let exchange = try persistence.loadExchange(requestId: requestId)
                await bridgeService.respond(to: callbackId, with: [
                    "exchange": AnyCodable(exchange.map(StreamCodec.encodeExchange) as Any)
                ])
            } catch {
                DebugLog.log("[WebViewManager] Failed to load exchange (\(DebugLog.errorSummary(error)))")
                await bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
            }

        case "openExternalURL":
            guard let payload = message.payload,
                  let rawURL = payload["url"]?.value as? String,
                  rawURL.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let components = URLComponents(string: rawURL),
                  let scheme = components.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  components.host != nil,
                  let url = components.url else {
                DebugLog.log("[StreamMessageHandler] Rejected external URL")
                return
            }

            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }

        default:
            DebugLog.log("[StreamMessageHandler] Unknown message type: \(message.type)")
        }
    }

    func sendStreamLoaded(id: UUID, requestId: Int? = nil) async throws {
        guard let stream = try persistence.loadStream(id: id) else {
            await sendStreamLoadFailed(id: id, requestId: requestId, reason: "notFound")
            return
        }
        delegate?.setCurrentStreamIdForFileDrops(id)
        await delegate?.closePDFPaneIfShowingDifferentStream(id)
        // The document, its spans and both append queues TOGETHER, in one
        // transaction. A mixed-time snapshot can only be refused: consuming a row
        // not in the document loses it, while missing a row duplicates it later.
        // Their provenance stays in fragment coordinates until JavaScript places
        // it, because Swift has no document parser.
        let snapshot = try persistence.loadEditorSnapshot(streamId: id)
        let document = snapshot.document
        let spans = snapshot.spans
        let pendingAppends = snapshot.pendingAppends
        let appendInbox = snapshot.appendInbox
        let marginNotes = try persistence.loadMarginNotes(streamId: id)
        let streamPayload = StreamCodec.encodeStream(stream, document: document)
        var payload: [String: AnyCodable] = [
            "stream": AnyCodable(streamPayload),
            "sourceScope": AnyCodable(stream.sourceScope.rawValue),
            "scrollOffset": AnyCodable(document.scrollOffset),
            "spans": AnyCodable(StreamCodec.encodeSpans(spans)),
            "marginNotes": AnyCodable(StreamCodec.encodeMarginNotes(marginNotes)),
            "pendingAppends": AnyCodable(StreamCodec.encodePendingAppends(pendingAppends)),
            "appendInbox": AnyCodable(StreamCodec.encodeAppendInbox(appendInbox))
        ]
        if let requestId {
            payload["requestId"] = AnyCodable(requestId)
        }
        await bridgeService.send(BridgeMessage(type: "streamLoaded", payload: payload))
        ingestService?.enqueuePendingSources(for: id)
    }

    private func sendStreamLoadFailed(id: UUID, requestId: Int?, reason: String) async {
        var payload: [String: AnyCodable] = [
            "id": AnyCodable(id.uuidString),
            "reason": AnyCodable(reason)
        ]
        if let requestId {
            payload["requestId"] = AnyCodable(requestId)
        }
        await bridgeService.send(BridgeMessage(type: "streamLoadFailed", payload: payload))
    }

    private func decodeSpans(_ value: Any?, streamId: UUID) -> [ProvenanceSpan]? {
        guard let items = value as? [[String: Any]] else { return nil }
        var dropped = 0
        let spans = items.compactMap { item -> ProvenanceSpan? in
            guard let spanId = item["spanId"] as? String,
                  let start = intValue(item["start"]),
                  let end = intValue(item["end"]),
                  let origin = item["origin"] as? String,
                  let meta = metaString(item["meta"]),
                  let textHash = item["textHash"] as? String,
                  let createdAt = Self.dateValue(item["createdAt"]) else {
                dropped += 1
                return nil
            }

            return ProvenanceSpan(
                spanId: spanId,
                streamId: streamId,
                start: start,
                end: end,
                origin: origin,
                requestId: optionalString(item["requestId"]),
                sourceId: optionalString(item["sourceId"]),
                meta: meta,
                textHash: textHash,
                createdAt: createdAt
            )
        }
        if dropped > 0 {
            DebugLog.log("[StreamMessageHandler] Dropped \(dropped) malformed provenance span(s)")
        }
        return spans
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double,
           double.rounded(.towardZero) == double,
           double >= Double(Int.min),
           double <= Double(Int.max) {
            return Int(double)
        }
        return nil
    }

    private func optionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        return value as? String
    }

    private func metaString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value,
              !(value is NSNull),
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: double)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: Double(int))
        }
        return nil
    }

}
