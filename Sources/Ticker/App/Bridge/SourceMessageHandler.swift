import AppKit
import Foundation
import UniformTypeIdentifiers

protocol SourceMessageHandlerDelegate: AnyObject {
    func setFileDropContext(streamId: UUID?, allowsListFileDrops: Bool)
    func hidePDFPane() async
    func openSourceReference(_ source: SourceReference, sourceService: SourceService)
    func openPDFDestination(
        _ source: SourceReference,
        sourceService: SourceService,
        highlightId: String?,
        page: Int?,
        chunkId: UUID?,
        quote: String?
    ) async
    func beginPDFAnchorPick(streamId: UUID) async
}

enum OpenPDFDestinationFailure: Equatable {
    case damagedLink
    case missingSource
    case wrongStream

    var userMessage: String {
        switch self {
        case .damagedLink:
            return "This link is damaged and can't be opened."
        case .missingSource:
            return "This link points to a source that's no longer in this stream."
        case .wrongStream:
            return "This link points to a source in another stream."
        }
    }
}

final class SourceMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "setFileDropContext",
        "addSource",
        "removeSource",
        "retrySourceIndexing",
        "setSourceAIExclusion",
        "openSource",
        "openPdfDestination",
        "beginPdfAnchorPick",
        "saveImage",
    ]

    private let persistence: PersistenceService
    private let bridgeService: BridgeService
    private let sourceService: SourceService?
    private let ingestService: IngestService?
    private let assetService: AssetService
    private weak var delegate: SourceMessageHandlerDelegate?

    init?(container: ServiceContainer, delegate: SourceMessageHandlerDelegate) {
        guard let persistence = container.persistence else { return nil }
        self.persistence = persistence
        self.bridgeService = container.bridgeService
        self.sourceService = container.sourceService
        self.ingestService = container.ingestService
        self.assetService = container.assetService
        self.delegate = delegate
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "setFileDropContext":
            let mode = message.payload?["mode"]?.value as? String
            switch mode {
            case "stream":
                if let streamIdValue = message.payload?["streamId"]?.value as? String,
                   let streamId = UUID(uuidString: streamIdValue) {
                    delegate?.setFileDropContext(streamId: streamId, allowsListFileDrops: false)
                } else {
                    delegate?.setFileDropContext(streamId: nil, allowsListFileDrops: false)
                }
            case "list":
                delegate?.setFileDropContext(streamId: nil, allowsListFileDrops: true)
                await delegate?.hidePDFPane()
            default:
                delegate?.setFileDropContext(streamId: nil, allowsListFileDrops: false)
                await delegate?.hidePDFPane()
            }

        case "addSource":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid addSource payload or service unavailable")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid addSource payload or service unavailable")
                return
            }

            // Must run on main thread for NSOpenPanel
            await MainActor.run {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                // Note: "net.daringfireball.markdown" is the standard UTI for markdown files
                let markdownType = UTType(filenameExtension: "md") ?? UTType.plainText
                panel.allowedContentTypes = [.pdf, .plainText, .text, .sourceCode, markdownType, .png, .jpeg, .heic, .image]
                panel.message = "Select a file to attach"

                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        let source = try sourceService.addSource(from: url, to: streamId)
                        let sourcePayload = StreamCodec.encodeSource(source)
                        bridgeService.send(BridgeMessage(type: "sourceAdded", payload: ["source": AnyCodable(sourcePayload)]))
                        ingestService?.enqueue(source: source)
                    } catch {
                        DebugLog.log("[WebViewManager] Failed to add source (\(DebugLog.errorSummary(error)))")
                        bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
                    }
                }
            }

        case "removeSource":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid removeSource payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid removeSource payload")
                return
            }
            do {
                ingestService?.cancel(sourceId: id)
                try sourceService.removeSource(id: id)
                await bridgeService.send(BridgeMessage(type: "sourceRemoved", payload: ["id": AnyCodable(id.uuidString)]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to remove source (\(DebugLog.errorSummary(error)))")
                await bridgeService.send(BridgeMessage(type: "sourceRemoveError", payload: [
                    "id": AnyCodable(id.uuidString),
                    "error": AnyCodable(error.localizedDescription)
                ]))
            }

        case "retrySourceIndexing":
            guard let payload = message.payload,
                  let sourceIdValue = payload["sourceId"]?.value as? String,
                  let sourceId = UUID(uuidString: sourceIdValue),
                  let ingestService else {
                DebugLog.log("[WebViewManager] Invalid retrySourceIndexing payload or service unavailable")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid retrySourceIndexing payload or service unavailable")
                return
            }

            do {
                guard var source = try persistence.loadSource(id: sourceId) else {
                    await sendSourceError("Source not found.")
                    return
                }

                try persistence.updateSourceIndexStatus(sourceId, status: .pending)
                source.indexStatus = .pending
                await bridgeService.send(BridgeMessage(type: "sourceIndexStatusChanged", payload: [
                    "sourceId": AnyCodable(sourceId.uuidString),
                    "status": AnyCodable(SourceIndexStatus.pending.rawValue)
                ]))
                ingestService.enqueue(source: source)
            } catch {
                DebugLog.log("[WebViewManager] Failed to retry source indexing (\(DebugLog.errorSummary(error)))")
                await sendSourceError(error.localizedDescription)
            }

        case "setSourceAIExclusion":
            guard let payload = message.payload,
                  let sourceIdValue = payload["sourceId"]?.value as? String,
                  let sourceId = UUID(uuidString: sourceIdValue),
                  let excluded = payload["excluded"]?.value as? Bool else {
                DebugLog.log("[SourceMessageHandler] Invalid setSourceAIExclusion payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid setSourceAIExclusion payload")
                return
            }

            do {
                guard try persistence.loadSource(id: sourceId) != nil else {
                    await sendSourceError("Source not found.")
                    return
                }

                try persistence.setSourceAIExcluded(sourceId, excluded: excluded)
                DebugLog.log("[SourceMessageHandler] setSourceAIExclusion sourceId=\(sourceId.uuidString) excluded=\(excluded)")
            } catch {
                DebugLog.log("[SourceMessageHandler] Failed to set source AI exclusion (\(DebugLog.errorSummary(error)))")
                await sendSourceError(error.localizedDescription)
            }

        case "openSource":
            guard let payload = message.payload,
                  let sourceIdValue = payload["sourceId"]?.value as? String,
                  let sourceId = UUID(uuidString: sourceIdValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid openSource payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid openSource payload")
                return
            }

            do {
                guard let source = try persistence.loadSource(id: sourceId) else {
                    await sendSourceError("Source not found.")
                    return
                }
                delegate?.openSourceReference(source, sourceService: sourceService)
            } catch {
                DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
                await sendSourceError(error.localizedDescription)
            }

        case "openPdfDestination":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid openPdfDestination payload")
                await sendPDFDestinationFailure(.damagedLink)
                return
            }

            let parsedDestination = (payload["url"]?.value as? String).flatMap(TickerPDFURLParser.parse)
            let payloadSourceId = (payload["sourceId"]?.value as? String).flatMap(UUID.init(uuidString:))
            let sourceId = payloadSourceId ?? parsedDestination?.sourceId
            let highlightId = (payload["highlightId"]?.value as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? parsedDestination?.highlightId
            let page = payload["page"]?.intValue ?? parsedDestination?.page
            let chunkId = (payload["chunkId"]?.value as? String).flatMap(UUID.init(uuidString:))
                ?? parsedDestination?.chunkId
            let quote = (payload["quote"]?.value as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? parsedDestination?.quote

            do {
                let source: SourceReference
                let pageToOpen: Int?

                if let sourceId {
                    guard let loadedSource = try persistence.loadSource(id: sourceId) else {
                        DebugLog.log("[WebViewManager] PDF destination source is missing")
                        await sendPDFDestinationFailure(.missingSource)
                        return
                    }
                    source = loadedSource
                    pageToOpen = page
                } else if let highlightId {
                    guard UUID(uuidString: highlightId) != nil else {
                        DebugLog.log("[WebViewManager] Invalid PDF highlight destination")
                        await sendPDFDestinationFailure(.damagedLink)
                        return
                    }
                    guard let legacyDestination = try legacyPDFHighlightDestination(
                        streamId: streamId,
                        highlightId: highlightId
                    ) else {
                        DebugLog.log("[WebViewManager] PDF highlight destination is missing")
                        await sendPDFDestinationFailure(.missingSource)
                        return
                    }
                    source = legacyDestination.source
                    pageToOpen = page ?? legacyDestination.page
                } else {
                    DebugLog.log("[WebViewManager] Invalid openPdfDestination payload")
                    await sendPDFDestinationFailure(.damagedLink)
                    return
                }

                guard source.streamId == streamId else {
                    DebugLog.log("[WebViewManager] PDF destination source belongs to another stream")
                    await sendPDFDestinationFailure(.wrongStream)
                    return
                }
                guard source.fileType == .pdf else {
                    DebugLog.log("[WebViewManager] PDF destination source is not a PDF")
                    await sendPDFDestinationFailure(.damagedLink)
                    return
                }

                await delegate?.openPDFDestination(
                    source,
                    sourceService: sourceService,
                    highlightId: highlightId,
                    page: pageToOpen,
                    chunkId: chunkId,
                    quote: quote
                )
            } catch {
                DebugLog.log("[WebViewManager] Failed to open PDF destination (\(DebugLog.errorSummary(error)))")
                await sendPDFDestinationFailure(.damagedLink)
            }

        case "beginPdfAnchorPick":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue) else {
                DebugLog.log("[WebViewManager] Invalid beginPdfAnchorPick payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid beginPdfAnchorPick payload")
                return
            }

            await delegate?.beginPDFAnchorPick(streamId: streamId)

        case "saveImage":
            // Save base64-encoded image data to stream's assets folder
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let base64Data = payload["data"]?.value as? String,
                  let imageData = Data(base64Encoded: base64Data) else {
                DebugLog.log("[WebViewManager] Invalid saveImage payload")
                let requestId = message.payload?["requestId"]?.value as? String
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid saveImage payload")
                await bridgeService.send(BridgeMessage(type: "imageSaveError", payload: [
                    "error": AnyCodable("Invalid image data"),
                    "requestId": AnyCodable(requestId as Any)
                ]))
                return
            }

            let requestId = payload["requestId"]?.value as? String

            do {
                let relativePath = try assetService.saveImage(data: imageData, streamId: streamId)
                let assetUrl = "ticker-asset:///\(relativePath)"

                await bridgeService.send(BridgeMessage(type: "imageSaved", payload: [
                    "relativePath": AnyCodable(relativePath),
                    "assetUrl": AnyCodable(assetUrl),
                    "requestId": AnyCodable(requestId as Any)
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to save image (\(DebugLog.errorSummary(error)))")
                await bridgeService.send(BridgeMessage(type: "imageSaveError", payload: [
                    "error": AnyCodable(error.localizedDescription),
                    "requestId": AnyCodable(requestId as Any)
                ]))
            }

        default:
            DebugLog.log("[SourceMessageHandler] Unknown message type: \(message.type)")
        }
    }

    @MainActor
    private func sendSourceError(_ message: String) {
        bridgeService.send(BridgeMessage(type: "sourceError", payload: [
            "error": AnyCodable(message)
        ]))
    }

    @MainActor
    private func sendPDFDestinationFailure(_ failure: OpenPDFDestinationFailure) {
        sendSourceError(failure.userMessage)
    }

    private func legacyPDFHighlightDestination(
        streamId: UUID,
        highlightId: String
    ) throws -> (source: SourceReference, page: Int?)? {
        guard let highlightUUID = UUID(uuidString: highlightId),
              let stream = try persistence.loadStream(id: streamId) else {
            return nil
        }

        for source in stream.sources where source.fileType == .pdf {
            let highlights = try persistence.loadPDFHighlights(sourceId: source.id)
            if let highlight = highlights.first(where: { $0.id == highlightUUID }) {
                return (source, highlight.page)
            }
        }

        return nil
    }
}
