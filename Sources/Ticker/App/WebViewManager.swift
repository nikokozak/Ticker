import WebKit
import AppKit
final class WebViewManager: NSObject {
    let webView: DroppableWebView
    var rootView: NSView { hostView }
    private let settingsService: SettingsService
    private let deviceKeyService: DeviceKeyService
    let bridgeService: BridgeService
    private let bridgeRouter: BridgeRouter
    private var streamMessageHandler: StreamMessageHandler?
    let persistence: PersistenceService?
    private let sourceService: SourceService?
    private let ingestService: IngestService?
    let orchestrator: AIOrchestrator
    private let assetService: AssetService
    private var currentStreamIdForFileDrops: UUID?
    private var allowsListFileDrops = false
    private let hostView = NSView(frame: .zero)
    private let editorPaneView = NSView(frame: .zero)
    private let pdfPaneController = PDFReaderPaneController()
    private let lastOpenStreamDefaultsKey = "TickerLastOpenStreamId"
    private var activePDFPaneStreamId: UUID?
    private var shouldRestoreLastOpenStream = true
    private var didConsumeLaunchStreamRestore = false
    private var pendingLaunchOpenStreamId: UUID?
    private var pendingEditorSelectionRequests: [String: (String?) -> Void] = [:]
    private let editorSelectionTimeoutNanoseconds: UInt64 = 50_000_000

    @MainActor
    init(container: ServiceContainer) {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        self.settingsService = container.settingsService
        self.deviceKeyService = container.deviceKeyService
        self.bridgeService = container.bridgeService
        self.bridgeRouter = BridgeRouter(bridgeService: container.bridgeService)
        config.userContentController.add(bridgeService, name: "bridge")
        let schemeHandler = AssetSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "ticker-asset")
        let bundleHandler = BundleSchemeHandler()
        config.setURLSchemeHandler(bundleHandler, forURLScheme: "ticker-bundle")

        self.webView = DroppableWebView(frame: .zero, configuration: config)
        self.orchestrator = container.orchestrator
        self.persistence = container.persistence
        self.sourceService = container.sourceService
        self.ingestService = container.ingestService
        self.assetService = container.assetService
        super.init()
        if let streamHandler = StreamMessageHandler(container: container, delegate: self) {
            streamMessageHandler = streamHandler
            bridgeRouter.register(streamHandler)
        }
        if let sourceHandler = SourceMessageHandler(container: container, delegate: self) {
            bridgeRouter.register(sourceHandler)
        }
        if let aiHandler = AIMessageHandler(container: container) {
            bridgeRouter.register(aiHandler)
        }
        bridgeRouter.register(ProxyAuthHandler(container: container))
        bridgeRouter.register(SettingsMessageHandler(container: container) {
            container.settingsService.allSettings()
        })
        bridgeRouter.register(SearchMessageHandler(container: container))
        webView.translatesAutoresizingMaskIntoConstraints = false
        configureMainLayout()
        configurePDFPaneCallbacks()

        webView.navigationDelegate = self
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        bridgeService.webView = webView
        bridgeService.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        webView.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        Task { [weak self] in
            guard let self else { return }
            deviceKeyService.onStateChange = { [weak self] state in
                Task { @MainActor in
                    self?.bridgeService.send(BridgeMessage(
                        type: "proxyAuthState",
                        payload: ["state": AnyCodable(state.rawValue)]
                    ))
                }
            }
            await deviceKeyService.initialize()
        }
    }

    private func configureMainLayout() {
        hostView.autoresizingMask = [.width, .height]

        let pdfPaneView = pdfPaneController.view
        pdfPaneView.translatesAutoresizingMaskIntoConstraints = false
        editorPaneView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(pdfPaneView)
        hostView.addSubview(editorPaneView)

        NSLayoutConstraint.activate([
            pdfPaneView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            pdfPaneView.topAnchor.constraint(equalTo: hostView.topAnchor),
            pdfPaneView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

            editorPaneView.leadingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor),
            editorPaneView.topAnchor.constraint(equalTo: hostView.topAnchor),
            editorPaneView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            editorPaneView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])

        editorPaneView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: editorPaneView.leadingAnchor),
            webView.topAnchor.constraint(equalTo: editorPaneView.topAnchor),
            webView.trailingAnchor.constraint(equalTo: editorPaneView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: editorPaneView.bottomAnchor),
        ])
    }

    private func configurePDFPaneCallbacks() {
        pdfPaneController.highlightsProvider = { [weak self] sourceId in
            guard let self, let persistence = self.persistence else { return [] }
            do {
                return try persistence.loadPDFHighlights(sourceId: sourceId)
            } catch {
                DebugLog.log("[WebViewManager] Failed to load PDF highlights (\(DebugLog.errorSummary(error)))")
                return []
            }
        }
        pdfPaneController.onLinkSelection = { [weak self] payload in
            Task { @MainActor in
                guard let self, let persistence = self.persistence else { return }
                do {
                    try persistence.savePDFHighlight(payload.highlight)
                    self.sendPDFHighlightLinked(payload)
                } catch {
                    DebugLog.log("[WebViewManager] Failed to save PDF highlight (\(DebugLog.errorSummary(error)))")
                    self.sendSourceError("Could not save PDF highlight.")
                }
            }
        }
        pdfPaneController.onAnchorPlaced = { [weak self] payload in
            Task { @MainActor in
                guard let self else { return }
                guard let persistence = self.persistence else {
                    self.sendSourceError("Could not save PDF anchor.")
                    self.sendPDFAnchorPickCancelled(streamId: payload.streamId)
                    return
                }
                do {
                    try persistence.savePDFHighlight(payload.highlight)
                    self.sendPDFAnchorPlaced(payload)
                } catch {
                    DebugLog.log("[WebViewManager] Failed to save PDF anchor (\(DebugLog.errorSummary(error)))")
                    self.sendSourceError("Could not save PDF anchor.")
                    self.sendPDFAnchorPickCancelled(streamId: payload.streamId)
                }
            }
        }
        pdfPaneController.onAnchorPickCancelled = { [weak self] streamId in
            Task { @MainActor in
                self?.sendPDFAnchorPickCancelled(streamId: streamId)
            }
        }
        pdfPaneController.onPageChanged = { [weak self] sourceId, pageIndex in
            guard let self, let persistence = self.persistence else { return }
            do {
                try persistence.saveSourceLastPageIndex(sourceId: sourceId, pageIndex: pageIndex)
            } catch {
                DebugLog.log("[WebViewManager] Failed to save PDF page position (\(DebugLog.errorSummary(error)))")
            }
        }
        pdfPaneController.onClose = { [weak self] in
            Task { @MainActor in
                self?.activePDFPaneStreamId = nil
                self?.sendPDFPaneStateChanged(visible: false)
            }
        }
    }

    @MainActor
    private func handleDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        guard let streamId = currentStreamIdForFileDrops else {
            guard allowsListFileDrops else {
                bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                    "error": AnyCodable("Drop files in a stream, or return to Streams to create one from PDF.")
                ]))
                return
            }
            handleDroppedFilesFromStreamList(urls)
            return
        }

        for url in urls {
            if isImageFile(url) {
                processDroppedImage(url, streamId: streamId)
            } else {
                processDroppedDocument(url, streamId: streamId)
            }
        }
    }

    @MainActor
    private func handleDroppedFilesFromStreamList(_ urls: [URL]) {
        guard let persistence else {
            bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                "error": AnyCodable("Sources are unavailable right now.")
            ]))
            return
        }

        guard let pdfURL = urls.first(where: { SourceFileType(from: $0) == .pdf }) else {
            bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                "error": AnyCodable("Drop a PDF on Streams to create a new stream.")
            ]))
            return
        }

        do {
            let streamTitle = SourceShortTitle.derive(displayName: pdfURL.lastPathComponent)
            let createdStream = try persistence.createStream(title: streamTitle)
            currentStreamIdForFileDrops = createdStream.id

            processDroppedDocument(pdfURL, streamId: createdStream.id)

            guard let reloadedStream = try persistence.loadStream(id: createdStream.id) else {
                bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                    "error": AnyCodable("Created stream but failed to open it.")
                ]))
                return
            }

            let document = try persistence.loadOrCreateStreamDocument(streamId: createdStream.id)
            let spans = try persistence.loadSpans(streamId: createdStream.id)
            let marginNotes = try persistence.loadMarginNotes(streamId: createdStream.id)
            let streamPayload = StreamCodec.encodeStream(reloadedStream, document: document)
            let streamLoadedPayload: [String: AnyCodable] = [
                "stream": AnyCodable(streamPayload),
                "sourceScope": AnyCodable(reloadedStream.sourceScope.rawValue),
                "scrollOffset": AnyCodable(document.scrollOffset),
                "spans": AnyCodable(StreamCodec.encodeSpans(spans)),
                "marginNotes": AnyCodable(StreamCodec.encodeMarginNotes(marginNotes))
            ]
            bridgeService.send(BridgeMessage(type: "streamLoaded", payload: streamLoadedPayload))

            let summaries = try persistence.loadStreamSummaries()
            let payload = StreamCodec.encodeSummaries(summaries)
            bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: [
                "streams": payload["streams"]!
            ]))
        } catch {
            DebugLog.log("[WebViewManager] Failed to create stream from dropped PDF (\(DebugLog.errorSummary(error)))")
            bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                "error": AnyCodable("Could not create stream from dropped PDF.")
            ]))
            currentStreamIdForFileDrops = nil
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    @MainActor
    private func processDroppedImage(_ url: URL, streamId: UUID) {
        let assetService = assetService
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let relativePath = try await Task.detached(priority: .utility) {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    return try assetService.saveImage(from: url, streamId: streamId)
                }.value
                let assetUrl = "ticker-asset:///\(relativePath)"

                bridgeService.send(BridgeMessage(type: "imageDropped", payload: [
                    "relativePath": AnyCodable(relativePath),
                    "assetUrl": AnyCodable(assetUrl),
                    "streamId": AnyCodable(streamId.uuidString)
                ]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to import dropped image (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                    "error": AnyCodable("Could not import that image.")
                ]))
            }
        }
    }

    @MainActor
    private func processDroppedDocument(_ url: URL, streamId: UUID) {
        guard let sourceService else {
            bridgeService.send(BridgeMessage(type: "sourceError", payload: [
                "error": AnyCodable("Sources are unavailable right now.")
            ]))
            return
        }

        let ingestService = ingestService
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = try await Task.detached(priority: .utility) {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    return try sourceService.addSource(from: url, to: streamId)
                }.value
                let sourcePayload = StreamCodec.encodeSource(source)
                bridgeService.send(BridgeMessage(type: "sourceAdded", payload: ["source": AnyCodable(sourcePayload)]))
                ingestService?.enqueue(source: source)
                if source.fileType == .pdf {
                    openSourceReference(source, sourceService: sourceService)
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to import dropped document (\(DebugLog.errorSummary(error)))")
                bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
            }
        }
    }

    @MainActor
    private func sendSourceError(_ message: String) {
        bridgeService.send(BridgeMessage(type: "sourceError", payload: [
            "error": AnyCodable(message)
        ]))
    }

    @MainActor
    private func sendPDFHighlightLinked(_ payload: PDFHighlightLinkPayload) {
        bridgeService.send(BridgeMessage(
            type: "pdfHighlightLinked",
            payload: [
                "streamId": AnyCodable(payload.streamId.uuidString),
                "sourceId": AnyCodable(payload.highlight.sourceId.uuidString),
                "sourceName": AnyCodable(payload.sourceName),
                "shortTitle": AnyCodable(SourceShortTitle.derive(displayName: payload.sourceName)),
                "highlightId": AnyCodable(payload.highlight.id.uuidString),
                "page": AnyCodable(payload.highlight.page),
                "quote": AnyCodable(payload.highlight.quote)
            ]
        ))
    }

    @MainActor
    private func sendPDFPaneStateChanged(
        visible: Bool,
        streamId: UUID? = nil,
        sourceId: UUID? = nil,
        sourceName: String? = nil
    ) {
        var payload: [String: AnyCodable] = ["visible": AnyCodable(visible)]
        if let streamId {
            payload["streamId"] = AnyCodable(streamId.uuidString)
        }
        if let sourceId {
            payload["sourceId"] = AnyCodable(sourceId.uuidString)
        }
        if let sourceName {
            payload["sourceName"] = AnyCodable(sourceName)
            payload["shortTitle"] = AnyCodable(SourceShortTitle.derive(displayName: sourceName))
        }
        bridgeService.send(BridgeMessage(type: "pdfPaneStateChanged", payload: payload))
    }

    @MainActor
    private func sendPDFAnchorPlaced(_ payload: PDFHighlightLinkPayload) {
        bridgeService.send(BridgeMessage(
            type: "pdfAnchorPlaced",
            payload: [
                "streamId": AnyCodable(payload.streamId.uuidString),
                "sourceId": AnyCodable(payload.highlight.sourceId.uuidString),
                "sourceName": AnyCodable(payload.sourceName),
                "shortTitle": AnyCodable(SourceShortTitle.derive(displayName: payload.sourceName)),
                "highlightId": AnyCodable(payload.highlight.id.uuidString),
                "page": AnyCodable(payload.highlight.page)
            ]
        ))
    }

    @MainActor
    private func sendPDFAnchorPickCancelled(streamId: UUID) {
        bridgeService.send(BridgeMessage(
            type: "pdfAnchorPickCancelled",
            payload: ["streamId": AnyCodable(streamId.uuidString)]
        ))
    }

    private func openPDFSource(
        _ source: SourceReference,
        sourceService: SourceService,
        afterPresent: (@MainActor (PDFReaderPaneController) -> Void)? = nil
    ) {
        do {
            let url = try sourceService.accessFile(source)

            Task { @MainActor [weak self] in
                guard let self else {
                    url.stopAccessingSecurityScopedResource()
                    return
                }
                do {
                    try self.pdfPaneController.present(
                        url: url,
                        streamId: source.streamId,
                        sourceId: source.id,
                        displayName: source.displayName,
                        lastPageIndex: afterPresent == nil ? source.lastPageIndex : nil
                    )
                    self.activePDFPaneStreamId = source.streamId
                    self.sendPDFPaneStateChanged(
                        visible: true,
                        streamId: source.streamId,
                        sourceId: source.id,
                        sourceName: source.displayName
                    )
                    afterPresent?(self.pdfPaneController)
                } catch {
                    url.stopAccessingSecurityScopedResource()
                    self.activePDFPaneStreamId = nil
                    self.sendSourceError(error.localizedDescription)
                }
            }
        } catch {
            DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
            Task { @MainActor in
                sendSourceError(error.localizedDescription)
            }
        }
    }

    func openSourceReference(_ source: SourceReference, sourceService: SourceService) {
        if source.fileType == .pdf {
            openPDFSource(source, sourceService: sourceService)
        } else {
            do {
                let url = try sourceService.accessFile(source)
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                    url.stopAccessingSecurityScopedResource()
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
                Task { @MainActor in
                    sendSourceError(error.localizedDescription)
                }
            }
        }
    }

    func openPDFDestination(
        _ source: SourceReference,
        sourceService: SourceService,
        highlightId: String?,
        page: Int?,
        chunkId: UUID?,
        quote: String?
    ) async {
        guard source.fileType == .pdf else {
            await sendSourceError("Source is not a PDF.")
            return
        }

        let chunk = loadPDFDestinationChunk(id: chunkId, sourceId: source.id)

        let isAlreadyPresenting = await MainActor.run {
            pdfPaneController.isPresenting(sourceId: source.id)
        }

        if isAlreadyPresenting {
            await MainActor.run {
                activePDFPaneStreamId = source.streamId
                pdfPaneController.navigateToDestination(highlightId: highlightId, page: page, chunk: chunk, quote: quote)
            }
            return
        }

        openPDFSource(source, sourceService: sourceService) { controller in
            controller.navigateToDestination(highlightId: highlightId, page: page, chunk: chunk, quote: quote)
        }
    }

    private func loadPDFDestinationChunk(id chunkId: UUID?, sourceId: UUID) -> SourceChunk? {
        guard let chunkId, let persistence else {
            return nil
        }

        do {
            guard let chunk = try persistence.loadSourceChunk(id: chunkId),
                  chunk.sourceId == sourceId else {
                return nil
            }
            return chunk
        } catch {
            DebugLog.log("[WebViewManager] Failed to load source chunk for PDF destination (\(DebugLog.errorSummary(error)))")
            return nil
        }
    }

    func beginPDFAnchorPick(streamId: UUID) async {
        let didStart = await MainActor.run {
            guard activePDFPaneStreamId == streamId,
                  pdfPaneController.isPresenting(streamId: streamId) else {
                return false
            }
            return pdfPaneController.beginAnchorPickMode()
        }

        if !didStart {
            await sendSourceError("Open a PDF source before linking to PDF.")
            await sendPDFAnchorPickCancelled(streamId: streamId)
        }
    }

    func load() {
        loadWebContent()
    }

    func skipLaunchStreamRestore() {
        shouldRestoreLastOpenStream = false
    }

    func openStream(id: UUID) {
        shouldRestoreLastOpenStream = false
        if didConsumeLaunchStreamRestore {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.streamMessageHandler?.sendStreamLoaded(id: id)
                } catch {
                    DebugLog.log("[WebViewManager] Failed to open stream from shell (\(DebugLog.errorSummary(error)))")
                }
            }
        } else {
            pendingLaunchOpenStreamId = id
        }
    }

    private func loadWebContent() {
        #if DEBUG
        if let url = URL(string: "http://localhost:6660") {
            webView.load(URLRequest(url: url))
        }
        #else
        if let url = URL(string: "ticker-bundle:///index.html") {
            webView.load(URLRequest(url: url))
        }
        #endif
    }

    @MainActor
    func currentPDFSelectionText() -> String? {
        pdfPaneController.currentSelectedText()
    }

    @MainActor
    func handlePDFFindShortcutIfFocused() -> Bool {
        pdfPaneController.handleFindShortcutIfFocused()
    }

    @MainActor
    func handlePDFFindBarKeyEvent(_ event: NSEvent) -> Bool {
        pdfPaneController.handleFindBarKeyEvent(event)
    }

    @MainActor
    func requestEditorSelection() async -> String? {
        await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString

            pendingEditorSelectionRequests[requestId] = { text in
                continuation.resume(returning: Self.nonEmptyTrimmed(text))
            }

            bridgeService.send(BridgeMessage(
                type: "getEditorSelection",
                payload: ["requestId": AnyCodable(requestId)]
            ))

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: self?.editorSelectionTimeoutNanoseconds ?? 50_000_000)
                guard let resolver = self?.pendingEditorSelectionRequests.removeValue(forKey: requestId) else {
                    return
                }
                resolver(nil)
            }
        }
    }

    @MainActor
    private func resolveEditorSelectionResponse(_ message: BridgeMessage) {
        guard let requestId = message.payload?["requestId"]?.value as? String else {
            return
        }
        let text = message.payload?["text"]?.value as? String
        guard let resolver = pendingEditorSelectionRequests.removeValue(forKey: requestId) else {
            return
        }
        resolver(text)
    }

    private func handleMessage(_ message: BridgeMessage) {
        switch message.type {
        case "editorSelection":
            Task { @MainActor [weak self] in
                self?.resolveEditorSelectionResponse(message)
            }
            return
        default:
            break
        }

        Task { [weak self] in
            guard let self else { return }
            await bridgeRouter.route(message)
        }
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

}

extension WebViewManager: StreamMessageHandlerDelegate {
    func setCurrentStreamIdForFileDrops(_ streamId: UUID?) {
        currentStreamIdForFileDrops = streamId
        if let streamId {
            UserDefaults.standard.set(streamId.uuidString, forKey: lastOpenStreamDefaultsKey)
        }
    }

    func consumeLastOpenStreamIdForLaunchRestore() -> UUID? {
        guard !didConsumeLaunchStreamRestore else { return nil }
        didConsumeLaunchStreamRestore = true
        if let streamId = pendingLaunchOpenStreamId {
            pendingLaunchOpenStreamId = nil
            return streamId
        }
        guard shouldRestoreLastOpenStream,
              let value = UserDefaults.standard.string(forKey: lastOpenStreamDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    func clearCurrentStreamIdForFileDrops(ifMatches streamId: UUID) {
        if currentStreamIdForFileDrops == streamId { currentStreamIdForFileDrops = nil }
    }

    func closePDFPaneIfShowingDifferentStream(_ streamId: UUID) async {
        guard let activeStreamId = activePDFPaneStreamId, activeStreamId != streamId else { return }
        await MainActor.run {
            pdfPaneController.setVisible(false)
            activePDFPaneStreamId = nil
            sendPDFPaneStateChanged(visible: false)
        }
    }

    func removePDFHighlightAnnotations(ids: [String], sourceIds: [UUID]) async {
        guard !ids.isEmpty else { return }
        await MainActor.run {
            guard sourceIds.contains(where: { pdfPaneController.isPresenting(sourceId: $0) }) else { return }
            pdfPaneController.removeHighlightAnnotations(ids: ids)
        }
    }
}

extension WebViewManager: SourceMessageHandlerDelegate {
    func setFileDropContext(streamId: UUID?, allowsListFileDrops: Bool) {
        currentStreamIdForFileDrops = streamId
        self.allowsListFileDrops = allowsListFileDrops
    }

    func hidePDFPane() async {
        await MainActor.run {
            pdfPaneController.setVisible(false)
            activePDFPaneStreamId = nil
            sendPDFPaneStateChanged(visible: false)
        }
    }
}

extension WebViewManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.log("[WebViewManager] WebView started loading")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.log("[WebViewManager] WebView finished loading")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("[WebViewManager] WebView navigation failed (\(DebugLog.errorSummary(error)))")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("[WebViewManager] WebView provisional navigation failed (\(DebugLog.errorSummary(error)))")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Without this, a dead web content process leaves a permanent white window.
        DebugLog.log("[WebViewManager] Web content process terminated; reloading")
        webView.reload()
    }
}
