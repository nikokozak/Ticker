import WebKit
import AppKit
final class WebViewManager: NSObject {
    let webView: DroppableWebView
    var rootView: NSView { hostView }
    private let settingsService: SettingsService
    private let deviceKeyService: DeviceKeyService
    let bridgeService: BridgeService
    private let bridgeRouter: BridgeRouter
    let persistence: PersistenceService?
    private let sourceService: SourceService?
    let orchestrator: AIOrchestrator
    private var mlxClassifier: MLXClassifier?
    private var classifierSkipped = false
    private let assetService: AssetService
    private var currentStreamIdForFileDrops: UUID?
    private var allowsListFileDrops = false
    private let hostView = NSView(frame: .zero)
    private let editorPaneView = NSView(frame: .zero)
    private let pdfPaneController = PDFReaderPaneController()
    private var activePDFPaneStreamId: UUID?
    init(container: ServiceContainer) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

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
        self.assetService = container.assetService
        super.init()
        if let streamHandler = StreamMessageHandler(container: container, delegate: self) {
            bridgeRouter.register(streamHandler)
        }
        if let sourceHandler = SourceMessageHandler(container: container, delegate: self) {
            bridgeRouter.register(sourceHandler)
        }
        if let aiHandler = AIMessageHandler(container: container) {
            bridgeRouter.register(aiHandler)
        }
        bridgeRouter.register(ProxyAuthHandler(container: container))
        bridgeRouter.register(SettingsMessageHandler(container: container) { [weak self] in
            self?.settingsWithClassifierState() ?? container.settingsService.allSettings()
        })
        bridgeRouter.register(SearchMessageHandler(container: container))
        webView.translatesAutoresizingMaskIntoConstraints = false
        configureMainLayout()
        configurePDFPaneCallbacks()

        webView.navigationDelegate = self
        bridgeService.webView = webView
        bridgeService.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        webView.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        Task { [weak self] in
            guard let self else { return }
            await deviceKeyService.onStateChange = { [weak self] state in
                self?.bridgeService.send(BridgeMessage(
                    type: "proxyAuthState",
                    payload: ["state": AnyCodable(state.rawValue)]
                ))
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
            guard let self, let persistence = self.persistence else { return }
            do {
                try persistence.savePDFHighlight(payload.highlight)
                self.sendPDFHighlightLinked(payload)
            } catch {
                DebugLog.log("[WebViewManager] Failed to save PDF highlight (\(DebugLog.errorSummary(error)))")
                self.sendSourceError("Could not save PDF highlight.")
            }
        }
        pdfPaneController.onAnchorPlaced = { [weak self] payload in
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
        pdfPaneController.onAnchorPickCancelled = { [weak self] streamId in
            self?.sendPDFAnchorPickCancelled(streamId: streamId)
        }
        pdfPaneController.onClose = { [weak self] in
            self?.activePDFPaneStreamId = nil
            self?.sendPDFPaneStateChanged(visible: false)
        }
    }

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
            let suggestedTitle = pdfURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let streamTitle = suggestedTitle.isEmpty ? "Untitled" : suggestedTitle
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
            let streamPayload = StreamCodec.encodeStream(reloadedStream, document: document)
            bridgeService.send(BridgeMessage(type: "streamLoaded", payload: [
                "stream": AnyCodable(streamPayload)
            ]))

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

    private func withSecurityScopedAccess<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }

    private func processDroppedImage(_ url: URL, streamId: UUID) {
        do {
            let imageData = try withSecurityScopedAccess(url) { try Data(contentsOf: url) }
            let relativePath = try assetService.saveImage(
                data: imageData,
                streamId: streamId,
                filename: url.lastPathComponent
            )

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

    private func processDroppedDocument(_ url: URL, streamId: UUID) {
        guard let sourceService else {
            bridgeService.send(BridgeMessage(type: "sourceError", payload: [
                "error": AnyCodable("Sources are unavailable right now.")
            ]))
            return
        }

        do {
            let source = try withSecurityScopedAccess(url) { try sourceService.addSource(from: url, to: streamId) }
            let sourcePayload = StreamCodec.encodeSource(source)
            bridgeService.send(BridgeMessage(type: "sourceAdded", payload: ["source": AnyCodable(sourcePayload)]))
            if source.fileType == .pdf {
                openSourceReference(source, sourceService: sourceService)
            }
        } catch {
            DebugLog.log("[WebViewManager] Failed to import dropped document (\(DebugLog.errorSummary(error)))")
            bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
        }
    }

    private func sendSourceError(_ message: String) {
        bridgeService.send(BridgeMessage(type: "sourceError", payload: [
            "error": AnyCodable(message)
        ]))
    }

    private func sendPDFHighlightLinked(_ payload: PDFHighlightLinkPayload) {
        bridgeService.send(BridgeMessage(
            type: "pdfHighlightLinked",
            payload: [
                "streamId": AnyCodable(payload.streamId.uuidString),
                "sourceId": AnyCodable(payload.highlight.sourceId.uuidString),
                "sourceName": AnyCodable(payload.sourceName),
                "highlightId": AnyCodable(payload.highlight.id.uuidString),
                "page": AnyCodable(payload.highlight.page),
                "quote": AnyCodable(payload.highlight.quote)
            ]
        ))
    }

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
        }
        bridgeService.send(BridgeMessage(type: "pdfPaneStateChanged", payload: payload))
    }

    private func sendPDFAnchorPlaced(_ payload: PDFHighlightLinkPayload) {
        bridgeService.send(BridgeMessage(
            type: "pdfAnchorPlaced",
            payload: [
                "streamId": AnyCodable(payload.streamId.uuidString),
                "sourceId": AnyCodable(payload.highlight.sourceId.uuidString),
                "sourceName": AnyCodable(payload.sourceName),
                "highlightId": AnyCodable(payload.highlight.id.uuidString),
                "page": AnyCodable(payload.highlight.page)
            ]
        ))
    }

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
                        displayName: source.displayName
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
            sendSourceError(error.localizedDescription)
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
                sendSourceError(error.localizedDescription)
            }
        }
    }

    func openPDFDestination(
        _ source: SourceReference,
        sourceService: SourceService,
        highlightId: String?,
        page: Int?
    ) async {
        guard source.fileType == .pdf else {
            sendSourceError("Source is not a PDF.")
            return
        }

        let isAlreadyPresenting = await MainActor.run {
            pdfPaneController.isPresenting(sourceId: source.id)
        }

        if isAlreadyPresenting {
            await MainActor.run {
                activePDFPaneStreamId = source.streamId
                pdfPaneController.navigateToHighlight(id: highlightId, page: page)
            }
            return
        }

        openPDFSource(source, sourceService: sourceService) { controller in
            controller.navigateToHighlight(id: highlightId, page: page)
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
            sendSourceError("Open a PDF source before linking to PDF.")
            sendPDFAnchorPickCancelled(streamId: streamId)
        }
    }

    func load() {
        loadWebContent()
        loadMLXClassifier()
        migrateExistingSourcesToRAG()
    }

    private func migrateExistingSourcesToRAG() {
        guard !SettingsService.proxyOnlyMode else { return }
        guard let persistence, let sourceService else { return }

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            let migrationService = RAGMigrationService(
                persistence: persistence,
                sourceService: sourceService
            )
            await migrationService.migrateExistingSources()
        }
    }

    private func loadMLXClassifier() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            DebugLog.log("MLX classifier skipped: running unit tests")
            classifierSkipped = true
            return
        }

        guard settingsService.smartRoutingEnabled else {
            DebugLog.log("MLX classifier skipped: smart routing disabled")
            classifierSkipped = true
            return
        }

        classifierSkipped = false
        Task {
            let classifier = MLXClassifier()
            self.mlxClassifier = classifier  // Store immediately so loading state is visible

            do {
                try await classifier.prepare()
                orchestrator.setClassifier(classifier)
                DebugLog.log("MLX classifier loaded and ready")
            } catch {
                DebugLog.log("Failed to load MLX classifier (\(DebugLog.errorSummary(error)))")
            }

            let settings = settingsWithClassifierState()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))
        }
    }

    private func loadWebContent() {
        #if DEBUG
        if let url = URL(string: "http://localhost:5173") {
            webView.load(URLRequest(url: url))
        }
        #else
        if let url = URL(string: "ticker-bundle:///index.html") {
            webView.load(URLRequest(url: url))
        }
        #endif
    }

    private func handleMessage(_ message: BridgeMessage) {
        Task { [weak self] in
            guard let self else { return }
            guard persistence != nil else {
                DebugLog.log("[WebViewManager] Persistence not available")
                return
            }
            await bridgeRouter.route(message)
        }
    }

    private func settingsWithClassifierState() -> [String: Any] {
        var settings = settingsService.allSettings()
        if let classifier = mlxClassifier {
            settings["classifierReady"] = classifier.isReady
            settings["classifierLoading"] = classifier.isLoading
            if let error = classifier.loadError {
                settings["classifierError"] = error.localizedDescription
            }
        } else if classifierSkipped {
            settings["classifierReady"] = false
            settings["classifierLoading"] = false
        } else {
            settings["classifierReady"] = false
            settings["classifierLoading"] = true
        }
        return settings
    }

}

extension WebViewManager: StreamMessageHandlerDelegate {
    func setCurrentStreamIdForFileDrops(_ streamId: UUID?) {
        currentStreamIdForFileDrops = streamId
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
}
