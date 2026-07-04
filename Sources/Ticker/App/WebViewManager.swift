import WebKit
import AppKit
import UniformTypeIdentifiers

/// Manages the WKWebView and Swift ↔ JS bridge
final class WebViewManager: NSObject {
    let webView: DroppableWebView
    var rootView: NSView { hostView }
    private let settingsService: SettingsService
    private let deviceKeyService: DeviceKeyService
    let bridgeService: BridgeService
    private let bridgeRouter = BridgeRouter()
    let persistence: PersistenceService?
    private let sourceService: SourceService?
    private let proxyService: ProxyLLMService  // For proxy-mode AI operations
    let orchestrator: AIOrchestrator  // Exposed for Quick Panel ephemeral AI
    private var mlxClassifier: MLXClassifier?
    private var classifierSkipped = false  // True if classifier loading was intentionally skipped

    // RAG services
    private let embeddingService: EmbeddingService
    private let chunkingService: ChunkingService
    private var retrievalService: RetrievalService?
    private var searchService: SearchService?

    // Asset management
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
        config.userContentController.add(bridgeService, name: "bridge")

        // Register custom URL scheme handler for local assets
        let schemeHandler = AssetSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "ticker-asset")

        // Register custom URL scheme handler for bundled web resources (Release mode)
        let bundleHandler = BundleSchemeHandler()
        config.setURLSchemeHandler(bundleHandler, forURLScheme: "ticker-bundle")

        self.webView = DroppableWebView(frame: .zero, configuration: config)
        self.proxyService = container.proxyService
        self.embeddingService = container.embeddingService
        self.chunkingService = container.chunkingService
        self.orchestrator = container.orchestrator
        self.persistence = container.persistence
        self.sourceService = container.sourceService
        self.retrievalService = container.retrievalService
        self.searchService = container.searchService
        self.assetService = container.assetService

        super.init()

        if let streamHandler = StreamMessageHandler(container: container, delegate: self) {
            bridgeRouter.register(streamHandler)
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        configureMainLayout()
        configurePDFPaneCallbacks()

        webView.navigationDelegate = self
        bridgeService.webView = webView
        bridgeService.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }

        // Handle file drops from native drag-and-drop
        webView.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        // Initialize DeviceKeyService and wire up state change callback
        Task { [weak self] in
            guard let self else { return }
            await deviceKeyService.onStateChange = { [weak self] state in
                // Push state to Web
                self?.bridgeService.send(BridgeMessage(
                    type: "proxyAuthState",
                    payload: ["state": AnyCodable(state.rawValue)]
                ))
            }
            // Initialize and validate cached key
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
        pdfPaneController.onLinkSelection = { [weak self] payload in
            self?.sendPDFHighlightLinked(payload)
        }
        pdfPaneController.onClose = { [weak self] in
            self?.activePDFPaneStreamId = nil
        }
    }

    /// Handle files dropped via native macOS drag-and-drop
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

    /// Handle drops while no stream is open (stream list/default page).
    /// A dropped PDF creates a new stream, attaches the source, and opens the document.
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

            // Refresh the list in the background so counts/titles stay current when user navigates back.
            let summaries = try persistence.loadStreamSummaries()
            let payload = StreamCodec.encodeSummaries(summaries)
            bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: payload))
        } catch {
            DebugLog.log("[WebViewManager] Failed to create stream from dropped PDF (\(DebugLog.errorSummary(error)))")
            bridgeService.send(BridgeMessage(type: "fileDropError", payload: [
                "error": AnyCodable("Could not create stream from dropped PDF.")
            ]))
            // Keep drop target unset when stream creation fails.
            currentStreamIdForFileDrops = nil
        }
    }

    /// Check if URL points to an image file
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

    /// Process a dropped image - save to assets and notify frontend
    private func processDroppedImage(_ url: URL, streamId: UUID) {
        do {
            let imageData = try withSecurityScopedAccess(url) { try Data(contentsOf: url) }
            let relativePath = try assetService.saveImage(
                data: imageData,
                streamId: streamId,
                filename: url.lastPathComponent
            )

            // Portable, privacy-preserving URL (no absolute user paths).
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

    /// Process a dropped document - add as source
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
                "sourceId": AnyCodable(payload.sourceId.uuidString),
                "sourceName": AnyCodable(payload.sourceName),
                "highlightId": AnyCodable(payload.highlightId),
                "page": AnyCodable(payload.page),
                "quote": AnyCodable(payload.quote)
            ]
        ))
    }

    private func openSourceReference(_ source: SourceReference, sourceService: SourceService) {
        do {
            let url = try sourceService.accessFile(source)

            if source.fileType == .pdf {
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
                    } catch {
                        url.stopAccessingSecurityScopedResource()
                        self.activePDFPaneStreamId = nil
                        self.sendSourceError(error.localizedDescription)
                    }
                }
            } else {
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                    url.stopAccessingSecurityScopedResource()
                }
            }
        } catch {
            DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
            sendSourceError(error.localizedDescription)
        }
    }

    func load() {
        loadWebContent()
        loadMLXClassifier()
        migrateExistingSourcesToRAG()
    }

    /// Migrate existing sources to RAG pipeline in background
    private func migrateExistingSourcesToRAG() {
        guard !SettingsService.proxyOnlyMode else { return }
        guard let persistence, let sourceService else { return }

        Task {
            // Wait 5 seconds after app launch to avoid blocking startup
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            let migrationService = RAGMigrationService(
                persistence: persistence,
                sourceService: sourceService
            )
            await migrationService.migrateExistingSources()
        }
    }

    /// Load the MLX classifier in the background (only if smart routing enabled)
    private func loadMLXClassifier() {
        // Unit tests should not trigger heavyweight MLX model downloads or background loading.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            DebugLog.log("MLX classifier skipped: running unit tests")
            classifierSkipped = true
            return
        }

        // Only load classifier if smart routing is enabled
        // Note: No vendor keys required - classifier runs locally, proxy handles routing
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
                // App continues to work, just uses direct GPT calls
            }

            // Notify frontend of classifier state change
            let settings = settingsWithClassifierState()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))
        }
    }

    private func loadWebContent() {
        // In development, load from Vite dev server
        // In production, load via custom scheme to avoid file:// URL issues with ES modules
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
        Task {
            await processMessage(message)
        }
    }

    private func processMessage(_ message: BridgeMessage) async {
        guard let persistence else {
            DebugLog.log("[WebViewManager] Persistence not available")
            return
        }

        switch message.type {
        case "loadStreams",
             "loadStream",
             "createStream",
             "updateStreamTitle",
             "deleteStream",
             "saveStreamDocument",
             "exportStream":
            await bridgeRouter.route(message)

        case "setFileDropContext":
            let mode = message.payload?["mode"]?.value as? String
            switch mode {
            case "stream":
                if let streamIdValue = message.payload?["streamId"]?.value as? String,
                   let streamId = UUID(uuidString: streamIdValue) {
                    currentStreamIdForFileDrops = streamId
                    allowsListFileDrops = false
                } else {
                    currentStreamIdForFileDrops = nil
                    allowsListFileDrops = false
                }
            case "list":
                currentStreamIdForFileDrops = nil
                allowsListFileDrops = true
                await MainActor.run {
                    pdfPaneController.setVisible(false)
                    activePDFPaneStreamId = nil
                }
            default:
                currentStreamIdForFileDrops = nil
                allowsListFileDrops = false
                await MainActor.run {
                    pdfPaneController.setVisible(false)
                    activePDFPaneStreamId = nil
                }
            }

        case "addSource":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let sourceService else {
                DebugLog.log("[WebViewManager] Invalid addSource payload or service unavailable")
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
                return
            }

            do {
                guard let source = try persistence.loadSource(id: sourceId) else {
                    sendSourceError("Source not found.")
                    return
                }
                openSourceReference(source, sourceService: sourceService)
            } catch {
                DebugLog.log("[WebViewManager] Failed to open source (\(DebugLog.errorSummary(error)))")
                sendSourceError(error.localizedDescription)
            }

        case "thinkDocument":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String,
                  let query = payload["query"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid thinkDocument payload")
                return
            }

            let imageURLs = payload["imageURLs"]?.value as? [String] ?? []
            let imageDataURLs = assetService.assetsToDataURLs(imageURLs)
            if !imageDataURLs.isEmpty {
                DebugLog.log("ThinkDocument: Converting \(imageURLs.count) images to data URLs")
            }

            var streamIdForRAG: UUID? = nil
            var sourceContext: String? = nil

            if let streamIdValue = payload["streamId"]?.value as? String,
               let streamId = UUID(uuidString: streamIdValue) {
                streamIdForRAG = streamId

                if let stream = try? persistence.loadStream(id: streamId) {
                    let combinedText = stream.sources
                        .compactMap { $0.extractedText }
                        .joined(separator: "\n\n---\n\n")
                    if !combinedText.isEmpty {
                        sourceContext = combinedText
                    }
                }
            }

            var resolvedQuery = query
            if let context = payload["context"]?.value as? String, !context.isEmpty {
                let cleanContext = context
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanContext.isEmpty {
                    resolvedQuery = "Regarding this context:\n\"\"\"\n\(cleanContext)\n\"\"\"\n\n\(resolvedQuery)"
                }
            }

            let onChunk: (String) -> Void = { [weak self] chunk in
                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIChunk",
                    payload: ["requestId": AnyCodable(requestId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: () -> Void = { [weak self] in
                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIComplete",
                    payload: ["requestId": AnyCodable(requestId)]
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                var payload: [String: AnyCodable] = [
                    "requestId": AnyCodable(requestId),
                    "error": AnyCodable(error.localizedDescription)
                ]

                if let proxyError = error as? ProxyLLMError {
                    payload["errorCode"] = AnyCodable(proxyError.errorCode)
                    if let proxyRequestId = proxyError.requestId {
                        payload["proxyRequestId"] = AnyCodable(proxyRequestId)
                    }

                    if case .quotaExceeded(let details) = proxyError {
                        payload["quotaScope"] = AnyCodable(details.scope)
                        payload["quotaLimit"] = AnyCodable(details.limit)
                        payload["quotaUsed"] = AnyCodable(details.used)
                        payload["quotaResetAt"] = AnyCodable(details.resetAt)
                    }

                    if case .rateLimited(let retryAfter) = proxyError {
                        if let seconds = retryAfter {
                            payload["retryAfter"] = AnyCodable(seconds)
                        }
                    }
                }

                self?.bridgeService.send(BridgeMessage(
                    type: "documentAIError",
                    payload: payload
                ))
            }

            Task { [weak self] in
                guard let self else { return }

                let proxyUsable = await self.deviceKeyService.currentState.isUsable

                guard proxyUsable else {
                    await MainActor.run {
                        onError(OrchestratorError.noProviderAvailable)
                    }
                    return
                }

                await self.orchestrator.route(
                    query: resolvedQuery,
                    queryImages: imageDataURLs,
                    streamId: streamIdForRAG,
                    priorCells: [],
                    sourceContext: sourceContext,
                    includeHeading: false,
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onError: onError,
                    onModelSelected: { [weak self] modelId in
                        self?.bridgeService.send(BridgeMessage(
                            type: "documentModelSelected",
                            payload: ["requestId": AnyCodable(requestId), "modelId": AnyCodable(modelId)]
                        ))
                    }
                )
            }

        case "loadSettings":
            let settings = settingsWithClassifierState()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))

        case "saveSettings":
            guard let payload = message.payload else {
                DebugLog.log("[WebViewManager] Invalid saveSettings payload")
                return
            }

            // Save OpenAI API key if provided
            if let openaiKey = payload["openaiAPIKey"]?.value as? String {
                settingsService.openaiAPIKey = openaiKey.isEmpty ? nil : openaiKey
            }

            // Save Anthropic API key if provided
            if let anthropicKey = payload["anthropicAPIKey"]?.value as? String {
                settingsService.anthropicAPIKey = anthropicKey.isEmpty ? nil : anthropicKey
            }

            // Save Perplexity API key if provided
            if let perplexityKey = payload["perplexityAPIKey"]?.value as? String {
                settingsService.perplexityAPIKey = perplexityKey.isEmpty ? nil : perplexityKey
            }

            // Save smart routing setting if provided
            if let smartRouting = payload["smartRoutingEnabled"]?.value as? Bool {
                settingsService.smartRoutingEnabled = smartRouting
            }

            // Save default model setting if provided
            if let modelValue = payload["defaultModel"]?.value as? String,
               let model = SettingsService.DefaultModel(rawValue: modelValue) {
                settingsService.defaultModel = model
            }

            // Save appearance setting if provided
            if let appearanceValue = payload["appearance"]?.value as? String,
               let appearance = SettingsService.Appearance(rawValue: appearanceValue) {
                settingsService.appearance = appearance
                // Notify AppDelegate to update window appearances
                NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
            }

            // Save diagnostics setting if provided
            if let diagnosticsEnabled = payload["diagnosticsEnabled"]?.value as? Bool {
                settingsService.diagnosticsEnabled = diagnosticsEnabled
            }

            // Save editor font setting if provided
            if let editorFontValue = payload["editorFont"]?.value as? String,
               let editorFont = SettingsService.EditorFont(rawValue: editorFontValue) {
                settingsService.editorFont = editorFont
            }

            // Save editor font size setting if provided
            if let editorFontSize = payload["editorFontSize"]?.value as? Double {
                settingsService.editorFontSize = editorFontSize
            } else if let editorFontSize = payload["editorFontSize"]?.value as? NSNumber {
                settingsService.editorFontSize = editorFontSize.doubleValue
            }

            // Save editor line spacing setting if provided
            if let editorLineSpacing = payload["editorLineSpacing"]?.value as? Double {
                settingsService.editorLineSpacing = editorLineSpacing
            } else if let editorLineSpacing = payload["editorLineSpacing"]?.value as? NSNumber {
                settingsService.editorLineSpacing = editorLineSpacing.doubleValue
            }

            // Send back updated settings
            let settings = settingsWithClassifierState()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))

        // MARK: - Proxy Auth (canonical names per docs)

        case "loadProxyAuth":
            // Pure read of cached state - no network call
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid loadProxyAuth payload")
                return
            }
            Task {
                let auth = await self.deviceKeyService.loadProxyAuth()
                let (limits, usage) = await self.deviceKeyService.getLimitsAndUsage()

                await MainActor.run {
                    var response: [String: AnyCodable] = [
                        "state": AnyCodable(auth.state.rawValue),
                        "supportId": AnyCodable(auth.supportId as Any),
                        "deviceId": AnyCodable(auth.deviceId)
                    ]

                    // Include limits if available
                    if let limits = limits {
                        response["limits"] = AnyCodable([
                            "reqsPerMin": limits.reqsPerMin as Any,
                            "tokensPerDay": limits.tokensPerDay as Any,
                            "tokensPerMonth": limits.tokensPerMonth as Any
                        ])
                    }

                    // Include usage if available
                    if let usage = usage {
                        response["usage"] = AnyCodable([
                            "reqsThisMinute": usage.reqsThisMinute as Any,
                            "tokensToday": usage.tokensToday as Any,
                            "tokensThisMonth": usage.tokensThisMonth as Any,
                            "dayResetAt": usage.dayResetAt as Any,
                            "monthResetAt": usage.monthResetAt as Any
                        ])
                    }

                    bridgeService.respond(to: callbackId, with: response)
                }
            }

        case "setProxyDeviceKey":
            guard let payload = message.payload,
                  let key = payload["key"]?.value as? String,
                  let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid setProxyDeviceKey payload")
                return
            }
            Task {
                do {
                    let result = try await self.deviceKeyService.setProxyDeviceKey(key)
                    let newAuth = await self.deviceKeyService.loadProxyAuth()
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(true),
                            "state": AnyCodable(newAuth.state.rawValue),
                            "supportId": AnyCodable(result.supportId),
                            "limits": AnyCodable([
                                "reqsPerMin": result.limits?.reqsPerMin as Any,
                                "tokensPerDay": result.limits?.tokensPerDay as Any,
                                "tokensPerMonth": result.limits?.tokensPerMonth as Any
                            ]),
                            "usage": AnyCodable([
                                "reqsThisMinute": result.usage?.reqsThisMinute as Any,
                                "tokensToday": result.usage?.tokensToday as Any,
                                "tokensThisMonth": result.usage?.tokensThisMonth as Any,
                                "dayResetAt": result.usage?.dayResetAt as Any,
                                "monthResetAt": result.usage?.monthResetAt as Any
                            ])
                        ])
                    }
                } catch {
                    let newAuth = await self.deviceKeyService.loadProxyAuth()
                    await MainActor.run {
                        bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
                        // Also push state change
                        bridgeService.send(BridgeMessage(
                            type: "proxyAuthState",
                            payload: ["state": AnyCodable(newAuth.state.rawValue)]
                        ))
                    }
                }
            }

        case "clearProxyDeviceKey":
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid clearProxyDeviceKey payload")
                return
            }
            Task {
                await self.deviceKeyService.clearProxyDeviceKey()
                let newAuth = await self.deviceKeyService.loadProxyAuth()
                await MainActor.run {
                    bridgeService.respond(to: callbackId, with: [
                        "success": AnyCodable(true),
                        "state": AnyCodable(newAuth.state.rawValue)
                    ])
                }
            }

        case "validateProxyDeviceKey", "refreshProxyAuth":
            // Re-validate cached key with server and return fresh limits/usage
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid validateProxyDeviceKey/refreshProxyAuth payload")
                return
            }
            Task {
                await self.deviceKeyService.revalidate()
                let newAuth = await self.deviceKeyService.loadProxyAuth()
                let (limits, usage) = await self.deviceKeyService.getLimitsAndUsage()

                await MainActor.run {
                    var response: [String: AnyCodable] = [
                        "state": AnyCodable(newAuth.state.rawValue),
                        "supportId": AnyCodable(newAuth.supportId as Any),
                        "deviceId": AnyCodable(newAuth.deviceId)
                    ]

                    if let limits = limits {
                        response["limits"] = AnyCodable([
                            "reqsPerMin": limits.reqsPerMin as Any,
                            "tokensPerDay": limits.tokensPerDay as Any,
                            "tokensPerMonth": limits.tokensPerMonth as Any
                        ])
                    }

                    if let usage = usage {
                        response["usage"] = AnyCodable([
                            "reqsThisMinute": usage.reqsThisMinute as Any,
                            "tokensToday": usage.tokensToday as Any,
                            "tokensThisMonth": usage.tokensThisMonth as Any,
                            "dayResetAt": usage.dayResetAt as Any,
                            "monthResetAt": usage.monthResetAt as Any
                        ])
                    }

                    bridgeService.respond(to: callbackId, with: response)
                }
            }

        // MARK: - Feedback & Support Bundle (D4/D5)

        case "submitFeedback":
            guard let callbackId = message.callbackId,
                  let payload = message.payload,
                  let feedbackType = payload["type"]?.value as? String,
                  let title = payload["title"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid submitFeedback payload")
                return
            }
            let description = payload["description"]?.value as? String
            let screenshotBase64 = payload["screenshot"]?.value as? String
            let screenshotContentType = payload["screenshotContentType"]?.value as? String

            Task {
                do {
                    let feedbackId = try await self.deviceKeyService.submitFeedback(
                        type: feedbackType,
                        title: title,
                        description: description,
                        screenshotBase64: screenshotBase64,
                        screenshotContentType: screenshotContentType
                    )
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(true),
                            "feedbackId": AnyCodable(feedbackId)
                        ])
                    }
                } catch {
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(false),
                            "error": AnyCodable(error.localizedDescription)
                        ])
                    }
                }
            }

        case "getSupportBundle":
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid getSupportBundle payload")
                return
            }
            Task {
                let bundle = await self.deviceKeyService.getSupportBundle()
                await MainActor.run {
                    bridgeService.respond(to: callbackId, with: [
                        "bundle": AnyCodable(bundle)
                    ])
                }
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
                return
            }
            let fullPath = assetService.assetURL(for: relativePath).path
            bridgeService.send(BridgeMessage(type: "assetPath", payload: [
                "relativePath": AnyCodable(relativePath),
                "fullPath": AnyCodable(fullPath)
            ]))

        case "hybridSearch":
            guard let payload = message.payload,
                  let query = payload["query"]?.value as? String,
                  let currentStreamIdStr = payload["currentStreamId"]?.value as? String,
                  let currentStreamId = UUID(uuidString: currentStreamIdStr),
                  let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid hybridSearch payload")
                return
            }

            let limit = payload["limit"]?.value as? Int ?? 20

            guard let searchService = searchService else {
                Task { @MainActor in
                    bridgeService.respondWithError(to: callbackId, error: "Search service not available")
                }
                return
            }

            Task {
                do {
                    let results = try await searchService.hybridSearch(
                        query: query,
                        currentStreamId: currentStreamId,
                        limit: limit
                    )

                    // Encode results to JSON-compatible format
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(results)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "currentStreamResults": AnyCodable(json["currentStreamResults"]),
                            "otherStreamResults": AnyCodable(json["otherStreamResults"])
                        ])
                    }
                } catch {
                    await MainActor.run {
                        bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
                    }
                }
            }

        default:
            DebugLog.log("[WebViewManager] Unknown message type: \(message.type)")
        }
    }

    /// Get settings enriched with classifier state
    private func settingsWithClassifierState() -> [String: Any] {
        var settings = settingsService.allSettings()
        if let classifier = mlxClassifier {
            settings["classifierReady"] = classifier.isReady
            settings["classifierLoading"] = classifier.isLoading
            if let error = classifier.loadError {
                settings["classifierError"] = error.localizedDescription
            }
        } else if classifierSkipped {
            // Classifier was intentionally skipped (smart routing disabled by user)
            settings["classifierReady"] = false
            settings["classifierLoading"] = false
        } else {
            // Classifier hasn't been loaded yet
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
        if currentStreamIdForFileDrops == streamId {
            currentStreamIdForFileDrops = nil
        }
    }

    func closePDFPaneIfShowingDifferentStream(_ streamId: UUID) async {
        if let activeStreamId = activePDFPaneStreamId, activeStreamId != streamId {
            await MainActor.run {
                pdfPaneController.setVisible(false)
                activePDFPaneStreamId = nil
            }
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
