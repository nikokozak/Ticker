import AppKit
import Foundation
import UniformTypeIdentifiers

protocol SourceMessageHandlerDelegate: AnyObject {
    func setFileDropContext(streamId: UUID?, allowsListFileDrops: Bool)
    func hidePDFPane() async
    func openSourceReference(_ source: SourceReference, sourceService: SourceService)
    func openPDFDestination(_ source: SourceReference, sourceService: SourceService, highlightId: String?, page: Int?) async
}

final class SourceMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "setFileDropContext",
        "addSource",
        "addSourceFromPath",
        "removeSource",
        "openSource",
        "openPdfDestination",
        "saveImage",
        "getAssetPath"
    ]

    private let persistence: PersistenceService
    private let bridgeService: BridgeService
    private let sourceService: SourceService?
    private let assetService: AssetService
    private weak var delegate: SourceMessageHandlerDelegate?

    init?(container: ServiceContainer, delegate: SourceMessageHandlerDelegate) {
        guard let persistence = container.persistence else { return nil }
        self.persistence = persistence
        self.bridgeService = container.bridgeService
        self.sourceService = container.sourceService
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
                    } catch {
                        DebugLog.log("[WebViewManager] Failed to add source (\(DebugLog.errorSummary(error)))")
                        bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
                    }
                }
            }

        case "addSourceFromPath":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let filePath = payload["path"]?.value as? String,
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid addSourceFromPath payload or service unavailable")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid addSourceFromPath payload or service unavailable")
                return
            }

            let url = URL(fileURLWithPath: filePath)
            do {
                let source = try sourceService.addSource(from: url, to: streamId)
                let sourcePayload = StreamCodec.encodeSource(source)
                bridgeService.send(BridgeMessage(type: "sourceAdded", payload: ["source": AnyCodable(sourcePayload)]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to add source from path (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
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
                try sourceService.removeSource(id: id)
                bridgeService.send(BridgeMessage(type: "sourceRemoved", payload: ["id": AnyCodable(id.uuidString)]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to remove source (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "sourceRemoveError", payload: [
                    "id": AnyCodable(id.uuidString),
                    "error": AnyCodable(error.localizedDescription)
                ]))
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
                    sendSourceError("Source not found.")
                    return
                }
                delegate?.openSourceReference(source, sourceService: sourceService)
            } catch {
                DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
                sendSourceError(error.localizedDescription)
            }

        case "openPdfDestination":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let sourceIdValue = payload["sourceId"]?.value as? String,
                  let sourceId = UUID(uuidString: sourceIdValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid openPdfDestination payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid openPdfDestination payload")
                return
            }

            do {
                guard let source = try persistence.loadSource(id: sourceId) else {
                    sendSourceError("Source not found.")
                    return
                }
                guard source.streamId == streamId else {
                    sendSourceError("Source does not belong to this stream.")
                    return
                }
                guard source.fileType == .pdf else {
                    sendSourceError("Source is not a PDF.")
                    return
                }

                let highlightId = (payload["highlightId"]?.value as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                await delegate?.openPDFDestination(
                    source,
                    sourceService: sourceService,
                    highlightId: highlightId,
                    page: payload["page"]?.intValue
                )
            } catch {
                DebugLog.log("[WebViewManager] Failed to open PDF destination (\(DebugLog.errorSummary(error)))")
                sendSourceError(error.localizedDescription)
            }

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
                bridgeService.send(BridgeMessage(type: "imageSaveError", payload: [
                    "error": AnyCodable("Invalid image data"),
                    "requestId": AnyCodable(requestId as Any)
                ]))
                return
            }

            let requestId = payload["requestId"]?.value as? String

            do {
                let relativePath = try assetService.saveImage(data: imageData, streamId: streamId)
                let assetUrl = "ticker-asset:///\(relativePath)"

                bridgeService.send(BridgeMessage(type: "imageSaved", payload: [
                    "relativePath": AnyCodable(relativePath),
                    "assetUrl": AnyCodable(assetUrl),
                    "requestId": AnyCodable(requestId as Any)
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to save image (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "imageSaveError", payload: [
                    "error": AnyCodable(error.localizedDescription),
                    "requestId": AnyCodable(requestId as Any)
                ]))
            }

        case "getAssetPath":
            // Get the full file path for an asset
            guard let payload = message.payload,
                  let relativePath = payload["relativePath"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid getAssetPath payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Invalid getAssetPath payload")
                return
            }
            let fullPath = assetService.assetURL(for: relativePath).path
            bridgeService.send(BridgeMessage(type: "assetPath", payload: [
                "relativePath": AnyCodable(relativePath),
                "fullPath": AnyCodable(fullPath)
            ]))

        default:
            DebugLog.log("[SourceMessageHandler] Unknown message type: \(message.type)")
        }
    }

    private func sendSourceError(_ message: String) {
        bridgeService.send(BridgeMessage(type: "sourceError", payload: [
            "error": AnyCodable(message)
        ]))
    }
}
