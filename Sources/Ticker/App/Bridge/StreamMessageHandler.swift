import AppKit
import Foundation

protocol StreamMessageHandlerDelegate: AnyObject {
    func setCurrentStreamIdForFileDrops(_ streamId: UUID?)
    func clearCurrentStreamIdForFileDrops(ifMatches streamId: UUID)
    func closePDFPaneIfShowingDifferentStream(_ streamId: UUID) async
    func removePDFHighlightAnnotations(ids: [String], sourceIds: [UUID]) async
}

enum PDFHighlightLinkReferenceExtractor {
    private static let tickerPDFURLPattern = #"ticker-pdf://[^\s<>"'\)\]]+"#

    static func highlightIds(in markdown: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: tickerPDFURLPattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var ids = Set<String>()

        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            guard let match,
                  let urlRange = Range(match.range, in: markdown) else {
                return
            }

            let rawURL = String(markdown[urlRange])
            guard let components = URLComponents(string: rawURL),
                  let highlightValue = components.queryItems?.first(where: {
                      $0.name.caseInsensitiveCompare("highlight") == .orderedSame
                  })?.value,
                  let id = UUID(uuidString: highlightValue) else {
                return
            }

            ids.insert(id.uuidString)
        }

        return ids
    }
}

final class StreamMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "loadStreams",
        "loadStream",
        "createStream",
        "updateStreamTitle",
        "deleteStream",
        "saveStreamDocument",
        "saveScrollPosition",
        "setSourceScope",
        "openExternalURL",
        "getExchange",
        "exportStream"
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
                bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: [
                    "streams": payload["streams"]!
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to load streams (\(DebugLog.errorSummary(error)))")
            }

        case "loadStream":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue) else {
                DebugLog.log("[WebViewManager] Invalid loadStream payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid loadStream payload")
                return
            }
            delegate?.setCurrentStreamIdForFileDrops(id)
            await delegate?.closePDFPaneIfShowingDifferentStream(id)
            do {
                if let stream = try persistence.loadStream(id: id) {
                    let document = try persistence.loadOrCreateStreamDocument(streamId: id)
                    let spans = try persistence.loadSpans(streamId: id)
                    let streamPayload = StreamCodec.encodeStream(stream, document: document)
                    let payload: [String: AnyCodable] = [
                        "stream": AnyCodable(streamPayload),
                        "sourceScope": AnyCodable(stream.sourceScope.rawValue),
                        "scrollOffset": AnyCodable(document.scrollOffset),
                        "spans": AnyCodable(StreamCodec.encodeSpans(spans))
                    ]
                    bridgeService.send(BridgeMessage(type: "streamLoaded", payload: payload))
                    ingestService?.enqueuePendingSources(for: id)
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to load stream (\(DebugLog.errorSummary(error)))")
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
                    "spans": AnyCodable(StreamCodec.encodeSpans([]))
                ]
                bridgeService.send(BridgeMessage(type: "streamLoaded", payload: payload))
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
                    bridgeService.send(BridgeMessage(type: "streamTitleUpdated", payload: ["id": AnyCodable(id.uuidString), "title": AnyCodable(title)]))
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
                try? assetService.deleteAssets(for: id)
                // Reload streams list
                let summaries = try persistence.loadStreamSummaries()
                let summariesPayload = StreamCodec.encodeSummaries(summaries)
                bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: [
                    "streams": summariesPayload["streams"]!
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to delete stream (\(DebugLog.errorSummary(error)))")
            }

        case "saveStreamDocument":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let markdown = payload["markdown"]?.value as? String,
                  let baseRevision = payload["baseRevision"]?.intValue,
                  let spans = decodeSpans(payload["spans"]?.value, streamId: streamId),
                  let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid saveStreamDocument payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid saveStreamDocument payload")
                return
            }
            do {
                let revision = try persistence.saveStreamDocument(
                    streamId: streamId,
                    markdown: markdown,
                    baseRevision: baseRevision,
                    spans: spans
                )
                await pruneUnreferencedPDFHighlights(streamId: streamId, markdown: markdown)
                await bridgeService.respond(to: callbackId, with: [
                    "revision": AnyCodable(revision)
                ])
                if let autoTitleService {
                    Task {
                        await autoTitleService.scheduleIfNeeded(streamId: streamId, markdown: markdown)
                    }
                }
            } catch let conflict as StreamDocumentRevisionConflict {
                await bridgeService.send(BridgeMessage(type: "streamDocumentConflict", payload: [
                    "streamId": AnyCodable(conflict.streamId.uuidString),
                    "markdown": AnyCodable(conflict.markdown),
                    "revision": AnyCodable(conflict.revision),
                    "spans": AnyCodable(StreamCodec.encodeSpans(conflict.spans))
                ]))
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

        case "getExchange":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String,
                  let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid getExchange payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid getExchange payload")
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

        case "exportStream":
            guard let payload = message.payload,
                  let streamIdString = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdString),
                  let format = payload["format"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid exportStream payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid exportStream payload")
                return
            }

            do {
                guard let stream = try persistence.loadStream(id: streamId) else {
                    DebugLog.log("[WebViewManager] Stream not found for export")
                    bridgeService.send(BridgeMessage(type: "exportError", payload: [
                        "streamId": AnyCodable(streamIdString),
                        "error": AnyCodable("Stream not found")
                    ]))
                    return
                }
                let document = try persistence.loadOrCreateStreamDocument(streamId: streamId)

                // Convert to export format
                let content = StreamCodec.formatStreamForExport(stream: stream, document: document, format: format)
                let fileExtension = format == "markdown" ? ".md" : ".txt"
                let suggestedName = StreamCodec.sanitizeFilename(stream.title) + fileExtension

                // Show save panel on main thread
                await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = suggestedName
                    // Use appropriate content type for the format
                    if format == "markdown" {
                        savePanel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
                    } else {
                        savePanel.allowedContentTypes = [.plainText]
                    }
                    savePanel.message = "Export stream as \(format == "markdown" ? "Markdown" : "Plain Text")"

                    let result = savePanel.runModal()
                    if result == .OK, let url = savePanel.url {
                        do {
                            try content.write(to: url, atomically: true, encoding: .utf8)
                            bridgeService.send(BridgeMessage(type: "exportComplete", payload: [
                                "streamId": AnyCodable(streamId.uuidString),
                                "path": AnyCodable(url.path)
                            ]))
                        } catch {
                            DebugLog.log("[WebViewManager] Failed to write export file (\(DebugLog.errorSummary(error)))")
                            bridgeService.send(BridgeMessage(type: "exportError", payload: [
                                "streamId": AnyCodable(streamId.uuidString),
                                "error": AnyCodable(error.localizedDescription)
                            ]))
                        }
                    } else {
                        // User canceled - no error, just inform frontend
                        bridgeService.send(BridgeMessage(type: "exportCanceled", payload: [
                            "streamId": AnyCodable(streamId.uuidString)
                        ]))
                    }
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to load stream for export (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "exportError", payload: [
                    "streamId": AnyCodable(streamIdString),
                    "error": AnyCodable(error.localizedDescription)
                ]))
            }

        default:
            DebugLog.log("[StreamMessageHandler] Unknown message type: \(message.type)")
        }
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
                  let createdAt = dateValue(item["createdAt"]) else {
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

    private func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: double)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: Double(int))
        }
        return nil
    }

    private func pruneUnreferencedPDFHighlights(streamId: UUID, markdown: String) async {
        do {
            let referencedHighlightIds = PDFHighlightLinkReferenceExtractor.highlightIds(in: markdown)
            let sourceIds = try persistence.loadStream(id: streamId)?.sources.map(\.id) ?? []
            let deletedHighlightIds = try persistence.deletePDFHighlights(
                sourceIds: sourceIds,
                excludingIds: Array(referencedHighlightIds)
            )
            // ponytail: undoing a deleted link after GC restores the markdown only; revive-on-undo would need soft-delete metadata.
            await delegate?.removePDFHighlightAnnotations(ids: deletedHighlightIds, sourceIds: sourceIds)
        } catch {
            DebugLog.log("[StreamMessageHandler] Failed to prune PDF highlights (\(DebugLog.errorSummary(error)))")
        }
    }
}
