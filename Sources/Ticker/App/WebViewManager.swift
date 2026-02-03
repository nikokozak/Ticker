import WebKit
import AppKit
import UniformTypeIdentifiers

/// Manages the WKWebView and Swift ↔ JS bridge
final class WebViewManager: NSObject {
    let webView: DroppableWebView
    let bridgeService: BridgeService
    let persistence: PersistenceService?
    private let sourceService: SourceService?
    private let aiService: AIService
    private let anthropicService: AnthropicService
    private let perplexityService: PerplexityService
    let orchestrator: AIOrchestrator  // Exposed for Quick Panel ephemeral AI
    private let dependencyService: DependencyService
    private var processingService: ProcessingService?
    private var mlxClassifier: MLXClassifier?
    private var classifierSkipped = false  // True if classifier loading was intentionally skipped
    private var classifierReady: CheckedContinuation<Void, Never>?
    private var isClassifierReady = false

    // RAG services
    private let embeddingService: EmbeddingService
    private let chunkingService: ChunkingService
    private var retrievalService: RetrievalService?
    private var searchService: SearchService?

    // Asset management
    private let assetService = AssetService()

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        self.bridgeService = BridgeService()
        config.userContentController.add(bridgeService, name: "bridge")

        // Register custom URL scheme handler for local assets
        let schemeHandler = AssetSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "ticker-asset")

        // Register custom URL scheme handler for bundled web resources (Release mode)
        let bundleHandler = BundleSchemeHandler()
        config.setURLSchemeHandler(bundleHandler, forURLScheme: "ticker-bundle")

        self.webView = DroppableWebView(frame: .zero, configuration: config)

        // Initialize services
        self.aiService = AIService()
        self.anthropicService = AnthropicService()
        self.perplexityService = PerplexityService()

        // Initialize RAG services
        self.embeddingService = EmbeddingService()
        self.chunkingService = ChunkingService()

        // Initialize orchestrator and register providers
        self.orchestrator = AIOrchestrator()
        orchestrator.register(aiService)
        orchestrator.register(anthropicService)
        orchestrator.register(perplexityService)

        // Initialize dependency service
        self.dependencyService = DependencyService()

        do {
            let p = try PersistenceService()
            self.persistence = p

            // Create SourceService with RAG components
            self.sourceService = SourceService(
                persistence: p,
                chunkingService: chunkingService,
                embeddingService: embeddingService
            )

            // Create RetrievalService and wire to orchestrator
            self.retrievalService = RetrievalService(
                persistence: p,
                embeddingService: embeddingService
            )
            orchestrator.setRetrievalService(retrievalService!)

            // Create SearchService for hybrid search
            self.searchService = SearchService(
                persistence: p,
                retrieval: retrievalService!,
                embedding: embeddingService
            )

            self.processingService = ProcessingService(
                orchestrator: orchestrator,
                dependencyService: dependencyService,
                persistence: p
            )
        } catch {
            DebugLog.log("[WebViewManager] Failed to initialize persistence (\(DebugLog.errorSummary(error)))")
            self.persistence = nil
            self.sourceService = nil
            self.retrievalService = nil
            self.searchService = nil
            self.processingService = nil
        }

        super.init()

        webView.autoresizingMask = [.width, .height]
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
        Task {
            await DeviceKeyService.shared.onStateChange = { [weak self] state in
                // Push state to Web
                self?.bridgeService.send(BridgeMessage(
                    type: "proxyAuthState",
                    payload: ["state": AnyCodable(state.rawValue)]
                ))
            }
            // Initialize and validate cached key
            await DeviceKeyService.shared.initialize()
        }
    }

    /// Handle files dropped via native macOS drag-and-drop
    private func handleDroppedFiles(_ urls: [URL]) {
        DebugLog.log("handleDroppedFiles: received \(urls.count) file(s)")

        // Get current stream ID from frontend
        bridgeService.send(BridgeMessage(
            type: "requestCurrentStreamId",
            payload: nil
        ))

        // Store URLs temporarily and wait for stream ID response
        pendingDroppedFiles = urls
    }

    private var pendingDroppedFiles: [URL] = []

    /// Called by frontend with the current stream ID
    private func processDroppedFiles(streamId: UUID) {
        DebugLog.log("processDroppedFiles: streamId=\(streamId), files=\(pendingDroppedFiles.count)")
        for url in pendingDroppedFiles {
            // Check if this is an image file
            if isImageFile(url) {
                DebugLog.log("processDroppedFiles: processing image")
                processDroppedImage(url, streamId: streamId)
            } else {
                DebugLog.log("processDroppedFiles: processing document")
                processDroppedDocument(url, streamId: streamId)
            }
        }

        pendingDroppedFiles = []
    }

    /// Check if URL points to an image file
    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Process a dropped image - save to assets and notify frontend
    private func processDroppedImage(_ url: URL, streamId: UUID) {
        do {
            let imageData = try Data(contentsOf: url)
            DebugLog.log("Read image data: \(imageData.count) bytes")
            let relativePath = try assetService.saveImage(data: imageData, streamId: streamId, filename: url.lastPathComponent)
            let fullPath = assetService.assetURL(for: relativePath).path
            DebugLog.log("Saved dropped image asset")

            // Use custom URL scheme that WKWebView can access
            let assetUrl = "ticker-asset://\(fullPath)"

            // Send to frontend to insert into focused cell
            bridgeService.send(BridgeMessage(type: "imageDropped", payload: [
                "relativePath": AnyCodable(relativePath),
                "fullPath": AnyCodable(fullPath),
                "assetUrl": AnyCodable(assetUrl),
                "streamId": AnyCodable(streamId.uuidString)
            ]))
            DebugLog.log("Sent imageDropped message")
        } catch {
            DebugLog.log("Failed to save dropped image (\(DebugLog.errorSummary(error)))")
            bridgeService.send(BridgeMessage(type: "imageDropError", payload: [
                "error": AnyCodable(error.localizedDescription)
            ]))
        }
    }

    /// Process a dropped document - add as source
    private func processDroppedDocument(_ url: URL, streamId: UUID) {
        guard let sourceService else {
            DebugLog.log("Source service unavailable")
            return
        }

        do {
            let source = try sourceService.addSource(from: url, to: streamId)
            let sourcePayload = encodeSource(source)
            bridgeService.send(BridgeMessage(type: "sourceAdded", payload: ["source": AnyCodable(sourcePayload)]))
        } catch {
            DebugLog.log("Failed to add dropped file (\(DebugLog.errorSummary(error)))")
            bridgeService.send(BridgeMessage(type: "sourceError", payload: ["error": AnyCodable(error.localizedDescription)]))
        }
    }

    func load() {
        loadWebContent()
        loadMLXClassifier()
        migrateExistingSourcesToRAG()
    }

    /// Migrate existing sources to RAG pipeline in background
    private func migrateExistingSourcesToRAG() {
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

    /// Load the MLX classifier in the background (only if smart routing enabled and Perplexity configured)
    private func loadMLXClassifier() {
        // Only load classifier if smart routing is enabled and Perplexity is configured
        guard SettingsService.shared.smartRoutingEnabled else {
            DebugLog.log("MLX classifier skipped: smart routing disabled")
            classifierSkipped = true
            return
        }
        guard let perplexityKey = SettingsService.shared.perplexityAPIKey,
              !perplexityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLog.log("MLX classifier skipped: Perplexity API key not configured")
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

            // Signal that classifier is ready (or failed)
            isClassifierReady = true
            classifierReady?.resume()
            classifierReady = nil

            // Notify frontend of classifier state change
            let settings = settingsWithClassifierState()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))
        }
    }

    /// Wait for the classifier to be ready (or skipped)
    private func waitForClassifier() async {
        if classifierSkipped || isClassifierReady { return }
        await withCheckedContinuation { continuation in
            if isClassifierReady {
                continuation.resume()
            } else {
                classifierReady = continuation
            }
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
        case "loadStreams":
            do {
                let summaries = try persistence.loadStreamSummaries()
                let formatter = ISO8601DateFormatter()
                let payload: [String: AnyCodable] = [
                    "streams": AnyCodable(summaries.map { summary -> [String: Any] in
                        var dict: [String: Any] = [
                            "id": summary.id.uuidString,
                            "title": summary.title,
                            "sourceCount": summary.sourceCount,
                            "cellCount": summary.cellCount,
                            "updatedAt": formatter.string(from: summary.updatedAt)
                        ]
                        if let previewText = summary.previewText {
                            dict["previewText"] = previewText
                        }
                        return dict
                    })
                ]
                bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: payload))
            } catch {
                DebugLog.log("[WebViewManager] Failed to load streams (\(DebugLog.errorSummary(error)))")
            }

        case "loadStream":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue) else {
                DebugLog.log("[WebViewManager] Invalid loadStream payload")
                return
            }
            do {
                if let stream = try persistence.loadStream(id: id) {
                    // Build dependency graph for this stream
                    dependencyService.buildGraph(from: stream.cells)

                    let streamPayload = encodeStream(stream)
                    bridgeService.send(BridgeMessage(type: "streamLoaded", payload: ["stream": AnyCodable(streamPayload)]))

                    // Process live blocks (async, after stream is loaded and classifier is ready)
                    if let processingService {
                        Task {
                            // Wait for classifier so live blocks route correctly
                            await self.waitForClassifier()
                            await processingService.processStreamOpen(
                                stream,
                                onBlockRefreshStart: { [weak self] blockId in
                                    self?.bridgeService.send(BridgeMessage(
                                        type: "blockRefreshStart",
                                        payload: ["cellId": AnyCodable(blockId.uuidString)]
                                    ))
                                },
                                onBlockChunk: { [weak self] blockId, chunk in
                                    self?.bridgeService.send(BridgeMessage(
                                        type: "blockRefreshChunk",
                                        payload: ["cellId": AnyCodable(blockId.uuidString), "chunk": AnyCodable(chunk)]
                                    ))
                                },
                                onBlockRefreshComplete: { [weak self] blockId, content in
                                    self?.bridgeService.send(BridgeMessage(
                                        type: "blockRefreshComplete",
                                        payload: ["cellId": AnyCodable(blockId.uuidString), "content": AnyCodable(content)]
                                    ))
                                },
                                onBlockRefreshError: { [weak self] blockId, error in
                                    self?.bridgeService.send(BridgeMessage(
                                        type: "blockRefreshError",
                                        payload: ["cellId": AnyCodable(blockId.uuidString), "error": AnyCodable(error.localizedDescription)]
                                    ))
                                },
                                onModelSelected: { [weak self] blockId, modelId in
                                    self?.bridgeService.send(BridgeMessage(
                                        type: "modelSelected",
                                        payload: ["cellId": AnyCodable(blockId.uuidString), "modelId": AnyCodable(modelId)]
                                    ))
                                }
                            )
                        }
                    }
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to load stream (\(DebugLog.errorSummary(error)))")
            }

        case "createStream":
            let title = (message.payload?["title"]?.value as? String) ?? "Untitled"
            do {
                let stream = try persistence.createStream(title: title)
                let streamPayload = encodeStream(stream)
                bridgeService.send(BridgeMessage(type: "streamLoaded", payload: ["stream": AnyCodable(streamPayload)]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to create stream (\(DebugLog.errorSummary(error)))")
            }

        case "updateStreamTitle":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue),
                  let title = payload["title"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid updateStreamTitle payload")
                return
            }
            do {
                if var stream = try persistence.loadStream(id: id) {
                    stream.title = title
                    try persistence.updateStream(stream)
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
                return
            }
            do {
                try persistence.deleteStream(id: id)
                // Also delete stream assets (images, etc.)
                try? assetService.deleteAssets(for: id)
                // Reload streams list
                let summaries = try persistence.loadStreamSummaries()
                let formatter = ISO8601DateFormatter()
                let summariesPayload: [String: AnyCodable] = [
                    "streams": AnyCodable(summaries.map { summary -> [String: Any] in
                        var dict: [String: Any] = [
                            "id": summary.id.uuidString,
                            "title": summary.title,
                            "sourceCount": summary.sourceCount,
                            "cellCount": summary.cellCount,
                            "updatedAt": formatter.string(from: summary.updatedAt)
                        ]
                        if let previewText = summary.previewText {
                            dict["previewText"] = previewText
                        }
                        return dict
                    })
                ]
                bridgeService.send(BridgeMessage(type: "streamsLoaded", payload: summariesPayload))
            } catch {
                DebugLog.log("[WebViewManager] Failed to delete stream (\(DebugLog.errorSummary(error)))")
            }

        case "saveCell":
            guard let payload = message.payload else {
                DebugLog.log("[WebViewManager] Invalid saveCell payload")
                return
            }
            do {
                var cell = try decodeCell(from: payload)

                // Parse references from content and resolve to UUIDs
                let identifiers = DependencyService.extractReferenceIdentifiers(from: cell.content)
                if !identifiers.isEmpty, let stream = try persistence.loadStream(id: cell.streamId) {
                    let resolvedRefs = DependencyService.resolveIdentifiers(identifiers, in: stream.cells)
                    cell = Cell(
                        id: cell.id,
                        streamId: cell.streamId,
                        content: cell.content,
                        restatement: cell.restatement,
                        originalPrompt: cell.originalPrompt,
                        type: cell.type,
                        order: cell.order,
                        modifiers: cell.modifiers,
                        versions: cell.versions,
                        activeVersionId: cell.activeVersionId,
                        processingConfig: cell.processingConfig,
                        references: resolvedRefs.isEmpty ? nil : resolvedRefs,
                        blockName: cell.blockName
                    )
                }

                // Update dependency graph
                dependencyService.updateCell(cell)

                try persistence.saveCell(cell)

                // Find dependents that need cascade updates
                let dependents = dependencyService.getCascadeDependents(of: cell.id)
                let dependentIds = dependents.map { $0.uuidString }

                bridgeService.send(BridgeMessage(type: "cellSaved", payload: [
                    "id": AnyCodable(cell.id.uuidString),
                    "dependents": AnyCodable(dependentIds)
                ]))

                // Trigger cascade updates for dependent blocks
                if !dependents.isEmpty, let processingService, let stream = try persistence.loadStream(id: cell.streamId) {
                    Task {
                        await processingService.processCascadeUpdate(
                            changedBlockId: cell.id,
                            in: stream,
                            onBlockRefreshStart: { [weak self] blockId in
                                self?.bridgeService.send(BridgeMessage(
                                    type: "blockRefreshStart",
                                    payload: ["cellId": AnyCodable(blockId.uuidString)]
                                ))
                            },
                            onBlockChunk: { [weak self] blockId, chunk in
                                self?.bridgeService.send(BridgeMessage(
                                    type: "blockRefreshChunk",
                                    payload: ["cellId": AnyCodable(blockId.uuidString), "chunk": AnyCodable(chunk)]
                                ))
                            },
                            onBlockRefreshComplete: { [weak self] blockId, content in
                                self?.bridgeService.send(BridgeMessage(
                                    type: "blockRefreshComplete",
                                    payload: ["cellId": AnyCodable(blockId.uuidString), "content": AnyCodable(content)]
                                ))
                            },
                            onBlockRefreshError: { [weak self] blockId, error in
                                self?.bridgeService.send(BridgeMessage(
                                    type: "blockRefreshError",
                                    payload: ["cellId": AnyCodable(blockId.uuidString), "error": AnyCodable(error.localizedDescription)]
                                ))
                            }
                        )
                    }
                }
            } catch {
                DebugLog.log("[WebViewManager] Failed to save cell (\(DebugLog.errorSummary(error)))")
            }

        case "deleteCell":
            guard let payload = message.payload,
                  let idValue = payload["id"]?.value as? String,
                  let id = UUID(uuidString: idValue) else {
                DebugLog.log("[WebViewManager] Invalid deleteCell payload")
                return
            }
            do {
                // Get cell content before deleting to extract asset URLs
                if let content = try persistence.getCellContent(id: id) {
                    cleanupAssetsInContent(content)
                }

                // Remove from dependency graph
                dependencyService.removeCell(id: id)

                try persistence.deleteCell(id: id)
                bridgeService.send(BridgeMessage(type: "cellDeleted", payload: ["id": AnyCodable(id.uuidString)]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to delete cell (\(DebugLog.errorSummary(error)))")
            }

        case "reorderBlocks":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let ordersRaw = payload["orders"]?.value as? [[String: Any]] else {
                DebugLog.log("[WebViewManager] Invalid reorderBlocks payload")
                return
            }
            do {
                // WebKit/JS numbers often arrive as Double (even if they look like integers in JS).
                // Be permissive here so reorder actually persists.
                let orders = ordersRaw.compactMap { dict -> (UUID, Int)? in
                    guard let idStr = dict["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let orderAny = dict["order"] else { return nil }

                    let order: Int?
                    if let o = orderAny as? Int {
                        order = o
                    } else if let o = orderAny as? Double {
                        order = Int(o)
                    } else if let o = orderAny as? NSNumber {
                        order = o.intValue
                    } else {
                        order = nil
                    }

                    guard let order else { return nil }
                    return (id, order)
                }
                if orders.isEmpty {
                    DebugLog.log("[WebViewManager] reorderBlocks payload had orders=[], skipping persistence")
                    bridgeService.send(BridgeMessage(type: "blocksReordered", payload: [:]))
                    return
                }
                try persistence.updateCellOrders(orders, streamId: streamId)
                bridgeService.send(BridgeMessage(type: "blocksReordered", payload: [:]))
            } catch {
                DebugLog.log("[WebViewManager] Failed to reorder blocks (\(DebugLog.errorSummary(error)))")
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
                        let sourcePayload = encodeSource(source)
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
                let sourcePayload = encodeSource(source)
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

        case "think":
            guard let payload = message.payload,
                  let cellId = payload["cellId"]?.value as? String,
                  let currentCell = payload["currentCell"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid think payload")
                return
            }

            // Parse image URLs for current cell (convert ticker-asset:// to data URLs)
            let currentCellImageURLs = payload["imageURLs"]?.value as? [String] ?? []
            var allImageDataURLs = assetService.assetsToDataURLs(currentCellImageURLs)
            if !allImageDataURLs.isEmpty {
                DebugLog.log("Think: Converting \(currentCellImageURLs.count) current cell images to data URLs")
            }

            // Get referenced content (from Quick Panel - the highlighted text/screenshot)
            let referencedContent = payload["referencedContent"]?.value as? String

            // Get referenced image URLs (screenshots from Quick Panel)
            let referencedImageURLs = payload["referencedImageURLs"]?.value as? [String] ?? []
            let referencedDataURLs = assetService.assetsToDataURLs(referencedImageURLs)
            if !referencedDataURLs.isEmpty {
                DebugLog.log("Think: Converting \(referencedImageURLs.count) referenced images to data URLs")
                allImageDataURLs.append(contentsOf: referencedDataURLs)
            }

            // Parse streamId for RAG retrieval and reference resolution
            var streamIdForRAG: UUID? = nil
            var sourceContext: String? = nil
            var streamCells: [Cell] = []

            if let streamIdValue = payload["streamId"]?.value as? String,
               let streamId = UUID(uuidString: streamIdValue) {
                streamIdForRAG = streamId

                if let stream = try? persistence.loadStream(id: streamId) {
                    streamCells = stream.cells

                    // Build fallback source context (used if RAG unavailable)
                    let combinedText = stream.sources
                        .compactMap { $0.extractedText }
                        .joined(separator: "\n\n---\n\n")
                    if !combinedText.isEmpty {
                        sourceContext = combinedText
                    }
                }
            }

            // Resolve @block-xxx references in the current cell content
            var resolvedCurrentCell = DependencyService.resolveReferencesInContent(currentCell, cells: streamCells)

            // If there's referenced content from Quick Panel, prepend it as context
            if let refContent = referencedContent, !refContent.isEmpty {
                // Strip HTML for cleaner context
                let cleanRef = refContent
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanRef.isEmpty {
                    resolvedCurrentCell = "Regarding this context:\n\"\"\"\n\(cleanRef)\n\"\"\"\n\n\(resolvedCurrentCell)"
                }
            }

            // Parse prior cells and resolve their references too (including images)
            var priorCells: [[String: Any]] = []
            if let priorCellsRaw = payload["priorCells"]?.value as? [[String: Any]] {
                for cell in priorCellsRaw {
                    var cellDict: [String: Any] = [:]
                    if let content = cell["content"] as? String {
                        // Resolve references in prior cell content
                        cellDict["content"] = DependencyService.resolveReferencesInContent(content, cells: streamCells)
                    }
                    if let type = cell["type"] as? String {
                        cellDict["type"] = type
                    }
                    // Convert prior cell images to data URLs
                    if let imageURLs = cell["imageURLs"] as? [String], !imageURLs.isEmpty {
                        cellDict["imageURLs"] = assetService.assetsToDataURLs(imageURLs)
                    }
                    priorCells.append(cellDict)
                }
            }

            // Define callbacks for streaming
            let onChunk: (String) -> Void = { [weak self] chunk in
                self?.bridgeService.send(BridgeMessage(
                    type: "aiChunk",
                    payload: ["cellId": AnyCodable(cellId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: () -> Void = { [weak self] in
                self?.bridgeService.send(BridgeMessage(
                    type: "aiComplete",
                    payload: ["cellId": AnyCodable(cellId)]
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                var payload: [String: AnyCodable] = [
                    "cellId": AnyCodable(cellId),
                    "error": AnyCodable(error.localizedDescription)
                ]

                // Add proxy-specific error details
                if let proxyError = error as? ProxyLLMError {
                    payload["errorCode"] = AnyCodable(proxyError.errorCode)
                    if let requestId = proxyError.requestId {
                        payload["requestId"] = AnyCodable(requestId)
                    }

                    // Add quota details for quota exceeded errors
                    if case .quotaExceeded(let details) = proxyError {
                        payload["quotaScope"] = AnyCodable(details.scope)
                        payload["quotaLimit"] = AnyCodable(details.limit)
                        payload["quotaUsed"] = AnyCodable(details.used)
                        payload["quotaResetAt"] = AnyCodable(details.resetAt)
                    }

                    // Add retry timing for rate limit errors
                    if case .rateLimited(let retryAfter) = proxyError {
                        if let seconds = retryAfter {
                            payload["retryAfter"] = AnyCodable(seconds)
                        }
                    }
                }

                self?.bridgeService.send(BridgeMessage(
                    type: "aiError",
                    payload: payload
                ))
            }

            // Route through orchestrator (handles smart routing and RAG retrieval internally)
            Task { [weak self] in
                guard let self else { return }

                // Check if any AI is available (proxy mode or vendor keys)
                let proxyUsable = await DeviceKeyService.shared.currentState.isUsable
                let hasVendorKey = self.aiService.isConfigured || self.anthropicService.isConfigured

                guard proxyUsable || hasVendorKey else {
                    await MainActor.run {
                        onError(OrchestratorError.noProviderAvailable)
                    }
                    return
                }

                await self.orchestrator.route(
                    query: resolvedCurrentCell,
                    queryImages: allImageDataURLs,
                    streamId: streamIdForRAG,
                    priorCells: priorCells,
                    sourceContext: sourceContext,
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onError: onError,
                    onModelSelected: { [weak self] modelId in
                        // Notify frontend which model is being used
                        self?.bridgeService.send(BridgeMessage(
                            type: "modelSelected",
                            payload: ["cellId": AnyCodable(cellId), "modelId": AnyCodable(modelId)]
                        ))
                    }
                )
            }

            // Generate restatement asynchronously (use original, not resolved, for better heading)
            aiService.generateRestatement(for: currentCell) { [weak self] restatement in
                guard let self, let restatement else { return }

                // Send restatement to frontend
                self.bridgeService.send(BridgeMessage(
                    type: "restatementGenerated",
                    payload: [
                        "cellId": AnyCodable(cellId),
                        "restatement": AnyCodable(restatement)
                    ]
                ))

                // Also persist to database if we have a stream ID and persistence
                if let persistence = self.persistence,
                   let cellUUID = UUID(uuidString: cellId) {
                    do {
                        try persistence.updateCellRestatement(cellId: cellUUID, restatement: restatement)
                    } catch {
                        DebugLog.log("Failed to save restatement (\(DebugLog.errorSummary(error)))")
                    }
                }
            }

        case "applyModifier":
            guard let payload = message.payload,
                  let cellId = payload["cellId"]?.value as? String,
                  let modifierPrompt = payload["modifierPrompt"]?.value as? String,
                  let currentContent = payload["currentContent"]?.value as? String else {
                DebugLog.log("[Modifier] Invalid applyModifier payload")
                return
            }

            DebugLog.log("[Modifier] Received request - cellId: \(cellId), promptLength=\(modifierPrompt.count)")

            // Check if configured
            guard aiService.isConfigured else {
                DebugLog.log("[Modifier] Error: API not configured")
                bridgeService.send(BridgeMessage(
                    type: "modifierError",
                    payload: ["cellId": AnyCodable(cellId), "error": AnyCodable("OpenAI API key not configured.")]
                ))
                return
            }

            // First, generate a short label for the modifier
            var modifierLabel = ""
            do {
                modifierLabel = try await generateModifierLabel(prompt: modifierPrompt)
                DebugLog.log("[Modifier] Generated label")
            } catch {
                DebugLog.log("[Modifier] Label generation failed (\(DebugLog.errorSummary(error))), using truncated prompt")
                modifierLabel = String(modifierPrompt.prefix(20))
            }

            // Create the modifier
            let modifierId = UUID()
            let modifier: [String: Any] = [
                "id": modifierId.uuidString,
                "prompt": modifierPrompt,
                "label": modifierLabel,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]

            // Send modifier created event
            DebugLog.log("[Modifier] Sending modifierCreated event")
            bridgeService.send(BridgeMessage(
                type: "modifierCreated",
                payload: ["cellId": AnyCodable(cellId), "modifier": AnyCodable(modifier)]
            ))

            // Track chunks for debugging
            var chunkCount = 0
            var totalContent = ""

            // Define callbacks for streaming
            let onChunk: (String) -> Void = { [weak self] chunk in
                chunkCount += 1
                totalContent += chunk
                if chunkCount <= 3 || chunkCount % 10 == 0 {
                    DebugLog.log("[Modifier] Chunk #\(chunkCount), total length: \(totalContent.count)")
                }
                self?.bridgeService.send(BridgeMessage(
                    type: "modifierChunk",
                    payload: ["cellId": AnyCodable(cellId), "modifierId": AnyCodable(modifierId.uuidString), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: () -> Void = { [weak self] in
                DebugLog.log("[Modifier] Complete - received \(chunkCount) chunks, total content length: \(totalContent.count)")
                self?.bridgeService.send(BridgeMessage(
                    type: "modifierComplete",
                    payload: ["cellId": AnyCodable(cellId), "modifierId": AnyCodable(modifierId.uuidString)]
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                DebugLog.log("[Modifier] Error (\(DebugLog.errorSummary(error)))")
                self?.bridgeService.send(BridgeMessage(
                    type: "modifierError",
                    payload: ["cellId": AnyCodable(cellId), "error": AnyCodable(error.localizedDescription)]
                ))
            }

            // Apply the modifier using AI
            DebugLog.log("[Modifier] Starting AI request")
            aiService.applyModifier(
                currentContent: currentContent,
                modifierPrompt: modifierPrompt,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError
            )

        case "exportStream":
            guard let payload = message.payload,
                  let streamIdString = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdString),
                  let format = payload["format"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid exportStream payload")
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

                // Convert to export format
                let content = formatStreamForExport(stream: stream, format: format)
                let fileExtension = format == "markdown" ? ".md" : ".txt"
                let suggestedName = sanitizeFilename(stream.title) + fileExtension

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
                SettingsService.shared.openaiAPIKey = openaiKey.isEmpty ? nil : openaiKey
            }

            // Save Anthropic API key if provided
            if let anthropicKey = payload["anthropicAPIKey"]?.value as? String {
                SettingsService.shared.anthropicAPIKey = anthropicKey.isEmpty ? nil : anthropicKey
            }

            // Save Perplexity API key if provided
            if let perplexityKey = payload["perplexityAPIKey"]?.value as? String {
                SettingsService.shared.perplexityAPIKey = perplexityKey.isEmpty ? nil : perplexityKey
            }

            // Save smart routing setting if provided
            if let smartRouting = payload["smartRoutingEnabled"]?.value as? Bool {
                SettingsService.shared.smartRoutingEnabled = smartRouting
            }

            // Save default model setting if provided
            if let modelValue = payload["defaultModel"]?.value as? String,
               let model = SettingsService.DefaultModel(rawValue: modelValue) {
                SettingsService.shared.defaultModel = model
            }

            // Save appearance setting if provided
            if let appearanceValue = payload["appearance"]?.value as? String,
               let appearance = SettingsService.Appearance(rawValue: appearanceValue) {
                SettingsService.shared.appearance = appearance
                // Notify AppDelegate to update window appearances
                NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
            }

            // Save diagnostics setting if provided
            if let diagnosticsEnabled = payload["diagnosticsEnabled"]?.value as? Bool {
                SettingsService.shared.diagnosticsEnabled = diagnosticsEnabled
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
                let auth = await DeviceKeyService.shared.loadProxyAuth()
                let (limits, usage) = await DeviceKeyService.shared.getLimitsAndUsage()

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
                    let result = try await DeviceKeyService.shared.setProxyDeviceKey(key)
                    let newAuth = await DeviceKeyService.shared.loadProxyAuth()
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
                    let newAuth = await DeviceKeyService.shared.loadProxyAuth()
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
                await DeviceKeyService.shared.clearProxyDeviceKey()
                let newAuth = await DeviceKeyService.shared.loadProxyAuth()
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
                await DeviceKeyService.shared.revalidate()
                let newAuth = await DeviceKeyService.shared.loadProxyAuth()
                let (limits, usage) = await DeviceKeyService.shared.getLimitsAndUsage()

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
                    let feedbackId = try await DeviceKeyService.shared.submitFeedback(
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
                let bundle = await DeviceKeyService.shared.getSupportBundle()
                await MainActor.run {
                    bridgeService.respond(to: callbackId, with: [
                        "bundle": AnyCodable(bundle)
                    ])
                }
            }

        case "currentStreamId":
            // Response from frontend with current stream ID for file drops
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue) else {
                DebugLog.log("[WebViewManager] Invalid currentStreamId payload")
                pendingDroppedFiles = []
                return
            }
            processDroppedFiles(streamId: streamId)

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
                let fullPath = assetService.assetURL(for: relativePath).path
                let assetUrl = "ticker-asset://\(fullPath)"

                bridgeService.send(BridgeMessage(type: "imageSaved", payload: [
                    "relativePath": AnyCodable(relativePath),
                    "fullPath": AnyCodable(fullPath),
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

    // MARK: - Encoding/Decoding Helpers

    private func encodeStream(_ stream: Stream) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": stream.id.uuidString,
            "title": stream.title,
            "sources": stream.sources.map { source -> [String: Any] in
                var dict: [String: Any] = [
                    "id": source.id.uuidString,
                    "streamId": source.streamId.uuidString,
                    "displayName": source.displayName,
                    "fileType": source.fileType.rawValue,
                    "status": source.status.rawValue,
                    "embeddingStatus": source.embeddingStatus.rawValue,
                    "addedAt": formatter.string(from: source.addedAt)
                ]
                if let pageCount = source.pageCount {
                    dict["pageCount"] = pageCount
                }
                return dict
            },
            "cells": stream.cells.map { cell -> [String: Any] in
                var dict: [String: Any] = [
                    "id": cell.id.uuidString,
                    "streamId": cell.streamId.uuidString,
                    "content": cell.content,
                    "type": cell.type.rawValue,
                    "order": cell.order,
                    "createdAt": formatter.string(from: cell.createdAt),
                    "updatedAt": formatter.string(from: cell.updatedAt)
                ]
                if let restatement = cell.restatement {
                    dict["restatement"] = restatement
                }
                if let originalPrompt = cell.originalPrompt {
                    dict["originalPrompt"] = originalPrompt
                }
                // Modifier stack fields
                if let modifiers = cell.modifiers, !modifiers.isEmpty {
                    dict["modifiers"] = modifiers.map { modifier -> [String: Any] in
                        [
                            "id": modifier.id.uuidString,
                            "prompt": modifier.prompt,
                            "label": modifier.label,
                            "createdAt": formatter.string(from: modifier.createdAt)
                        ]
                    }
                }
                if let versions = cell.versions, !versions.isEmpty {
                    dict["versions"] = versions.map { version -> [String: Any] in
                        [
                            "id": version.id.uuidString,
                            "content": version.content,
                            "modifierIds": version.modifierIds.map { $0.uuidString },
                            "createdAt": formatter.string(from: version.createdAt)
                        ]
                    }
                }
                if let activeVersionId = cell.activeVersionId {
                    dict["activeVersionId"] = activeVersionId.uuidString
                }
                // Processing fields
                if let processingConfig = cell.processingConfig {
                    var configDict: [String: Any] = [:]
                    if let refreshTrigger = processingConfig.refreshTrigger {
                        configDict["refreshTrigger"] = refreshTrigger.rawValue
                    }
                    if let schema = processingConfig.schema {
                        var schemaDict: [String: Any] = ["jsonSchema": schema.jsonSchema, "driftDetected": schema.driftDetected]
                        if let lastValidatedAt = schema.lastValidatedAt {
                            schemaDict["lastValidatedAt"] = formatter.string(from: lastValidatedAt)
                        }
                        configDict["schema"] = schemaDict
                    }
                    if let autoTransform = processingConfig.autoTransform {
                        configDict["autoTransform"] = [
                            "condition": autoTransform.condition,
                            "transformation": autoTransform.transformation
                        ]
                    }
                    if !configDict.isEmpty {
                        dict["processingConfig"] = configDict
                    }
                }
                if let references = cell.references, !references.isEmpty {
                    dict["references"] = references.map { $0.uuidString }
                }
                if let blockName = cell.blockName {
                    dict["blockName"] = blockName
                }
                if let sourceApp = cell.sourceApp {
                    dict["sourceApp"] = sourceApp
                }
                // Source binding
                if let sourceBinding = cell.sourceBinding {
                    var bindingDict: [String: Any] = ["sourceId": sourceBinding.sourceId.uuidString]
                    switch sourceBinding.location {
                    case .whole:
                        bindingDict["location"] = ["type": "whole"]
                    case .page(let page):
                        bindingDict["location"] = ["type": "page", "page": page]
                    case .pageRange(let start, let end):
                        bindingDict["location"] = ["type": "pageRange", "startPage": start, "endPage": end]
                    }
                    dict["sourceBinding"] = bindingDict
                } else {
                    dict["sourceBinding"] = NSNull()
                }
                return dict
            },
            "createdAt": formatter.string(from: stream.createdAt),
            "updatedAt": formatter.string(from: stream.updatedAt)
        ]
    }

    private func encodeSource(_ source: SourceReference) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": source.id.uuidString,
            "streamId": source.streamId.uuidString,
            "displayName": source.displayName,
            "fileType": source.fileType.rawValue,
            "status": source.status.rawValue,
            "addedAt": formatter.string(from: source.addedAt)
        ]
        if let pageCount = source.pageCount {
            dict["pageCount"] = pageCount
        }
        if source.extractedText != nil {
            dict["hasExtractedText"] = true
        }
        return dict
    }

    /// Generate a short label for a modifier prompt using AI
    private func generateModifierLabel(prompt: String) async throws -> String {
        return try await aiService.generateLabel(for: prompt)
    }

    /// Get settings enriched with classifier state
    private func settingsWithClassifierState() -> [String: Any] {
        var settings = SettingsService.shared.allSettings()
        if let classifier = mlxClassifier {
            settings["classifierReady"] = classifier.isReady
            settings["classifierLoading"] = classifier.isLoading
            if let error = classifier.loadError {
                settings["classifierError"] = error.localizedDescription
            }
        } else if classifierSkipped {
            // Classifier was intentionally skipped (smart routing disabled or no API key)
            settings["classifierReady"] = false
            settings["classifierLoading"] = false
        } else {
            // Classifier hasn't been loaded yet
            settings["classifierReady"] = false
            settings["classifierLoading"] = true
        }
        return settings
    }

    // MARK: - Export Helpers

    /// Format a stream for export as markdown or plain text
    private func formatStreamForExport(stream: Stream, format: String) -> String {
        var output = ""
        let isMarkdown = format == "markdown"

        // Title
        if isMarkdown {
            output += "# \(stream.title)\n\n"
        } else {
            output += "\(stream.title)\n\n"
        }

        // Cells
        let sortedCells = stream.cells.sorted(by: { $0.order < $1.order })
        for cell in sortedCells {
            let plainContent = stripHTML(cell.content)

            switch cell.type {
            case .text:
                output += plainContent + "\n\n"

            case .aiResponse:
                if isMarkdown {
                    output += "**AI Response**"
                    if let modelId = cell.modelId {
                        output += " *(\(modelId))*"
                    }
                    output += "\n"
                    if let prompt = cell.originalPrompt {
                        // Format multi-line prompts as proper blockquotes
                        let quotedPrompt = prompt.components(separatedBy: "\n")
                            .map { "> \($0)" }
                            .joined(separator: "\n")
                        output += "\(quotedPrompt)\n\n"
                    }
                } else {
                    output += "[AI Response"
                    if let modelId = cell.modelId { output += " - \(modelId)" }
                    output += "]\n"
                    if let prompt = cell.originalPrompt {
                        output += "Prompt: \(prompt)\n\n"
                    }
                }
                output += plainContent + "\n\n"

            case .quote:
                if isMarkdown {
                    output += "**Quote**"
                    if let sourceApp = cell.sourceApp {
                        output += " *(from \(sourceApp))*"
                    }
                    output += "\n\n"
                } else {
                    output += "[Quote"
                    if let sourceApp = cell.sourceApp { output += " - \(sourceApp)" }
                    output += "]\n"
                }
                output += plainContent + "\n\n"
            }

            output += isMarkdown ? "---\n\n" : "---\n\n"
        }

        // Sources
        if !stream.sources.isEmpty {
            output += isMarkdown ? "## Sources\n\n" : "Sources:\n"
            for source in stream.sources {
                output += "- \(source.displayName)\n"
            }
        }

        return output
    }

    /// Strip HTML tags from content and convert to plain text
    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributedString = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            // Fallback: basic regex-based stripping
            return html
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize a string for use as a filename
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidChars).joined(separator: "-")
    }

    private func decodeCell(from payload: [String: AnyCodable]) throws -> Cell {
        guard let idValue = payload["id"]?.value as? String,
              let id = UUID(uuidString: idValue),
              let streamIdValue = payload["streamId"]?.value as? String,
              let streamId = UUID(uuidString: streamIdValue),
              let content = payload["content"]?.value as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid cell payload"))
        }

        let typeRaw = payload["type"]?.value as? String ?? "text"
        let type = CellType(rawValue: typeRaw) ?? .text
        let order = payload["order"]?.value as? Int ?? 0
        let restatement = payload["restatement"]?.value as? String
        let originalPrompt = payload["originalPrompt"]?.value as? String

        // Decode modifier stack fields
        var modifiers: [Modifier]? = nil
        if let modifiersRaw = payload["modifiers"]?.value as? [[String: Any]] {
            modifiers = modifiersRaw.compactMap { dict -> Modifier? in
                guard let idStr = dict["id"] as? String,
                      let modId = UUID(uuidString: idStr),
                      let prompt = dict["prompt"] as? String,
                      let label = dict["label"] as? String else { return nil }
                return Modifier(id: modId, prompt: prompt, label: label)
            }
        }

        var versions: [CellVersion]? = nil
        if let versionsRaw = payload["versions"]?.value as? [[String: Any]] {
            versions = versionsRaw.compactMap { dict -> CellVersion? in
                guard let idStr = dict["id"] as? String,
                      let verId = UUID(uuidString: idStr),
                      let verContent = dict["content"] as? String,
                      let modifierIdsRaw = dict["modifierIds"] as? [String] else { return nil }
                let modifierIds = modifierIdsRaw.compactMap { UUID(uuidString: $0) }
                return CellVersion(id: verId, content: verContent, modifierIds: modifierIds)
            }
        }

        var activeVersionId: UUID? = nil
        if let activeVersionIdStr = payload["activeVersionId"]?.value as? String {
            activeVersionId = UUID(uuidString: activeVersionIdStr)
        }

        // Decode processing fields
        var processingConfig: ProcessingConfig? = nil
        if let configRaw = payload["processingConfig"]?.value as? [String: Any] {
            var config = ProcessingConfig()
            if let refreshTriggerRaw = configRaw["refreshTrigger"] as? String {
                config.refreshTrigger = RefreshTrigger(rawValue: refreshTriggerRaw)
            }
            if let schemaRaw = configRaw["schema"] as? [String: Any],
               let jsonSchema = schemaRaw["jsonSchema"] as? String {
                config.schema = BlockSchema(
                    jsonSchema: jsonSchema,
                    driftDetected: schemaRaw["driftDetected"] as? Bool ?? false
                )
            }
            if let autoTransformRaw = configRaw["autoTransform"] as? [String: Any],
               let condition = autoTransformRaw["condition"] as? String,
               let transformation = autoTransformRaw["transformation"] as? String {
                config.autoTransform = AutoTransformRule(condition: condition, transformation: transformation)
            }
            processingConfig = config
        }

        var references: [UUID]? = nil
        if let referencesRaw = payload["references"]?.value as? [String] {
            references = referencesRaw.compactMap { UUID(uuidString: $0) }
        }

        let blockName = payload["blockName"]?.value as? String
        let sourceApp = payload["sourceApp"]?.value as? String

        // Decode source binding
        var sourceBinding: SourceBinding? = nil
        if let bindingRaw = payload["sourceBinding"]?.value as? [String: Any],
           let sourceIdStr = bindingRaw["sourceId"] as? String,
           let sourceId = UUID(uuidString: sourceIdStr),
           let locationRaw = bindingRaw["location"] as? [String: Any],
           let locationType = locationRaw["type"] as? String {
            let location: SourceLocation
            switch locationType {
            case "page":
                if let page = locationRaw["page"] as? Int {
                    location = .page(page)
                } else {
                    location = .whole
                }
            case "pageRange":
                if let start = locationRaw["startPage"] as? Int,
                   let end = locationRaw["endPage"] as? Int {
                    location = .pageRange(start, end)
                } else {
                    location = .whole
                }
            default:
                location = .whole
            }
            sourceBinding = SourceBinding(sourceId: sourceId, location: location)
        }

        return Cell(
            id: id,
            streamId: streamId,
            content: content,
            restatement: restatement,
            originalPrompt: originalPrompt,
            type: type,
            sourceBinding: sourceBinding,
            order: order,
            modifiers: modifiers,
            versions: versions,
            activeVersionId: activeVersionId,
            processingConfig: processingConfig,
            references: references,
            blockName: blockName,
            sourceApp: sourceApp
        )
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

    // MARK: - Asset Cleanup

    /// Extract ticker-asset:// URLs from HTML content and delete the associated files
    private func cleanupAssetsInContent(_ content: String) {
        // Match ticker-asset:// URLs in src attributes
        let pattern = #"ticker-asset:///?([^"'\s>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: range)

        for match in matches {
            guard let pathRange = Range(match.range(at: 1), in: content) else { continue }
            let relativePath = String(content[pathRange])

            // Delete the asset file
            do {
                try assetService.deleteAsset(relativePath: relativePath)
            } catch {
                DebugLog.log("[WebViewManager] Failed to delete asset (\(DebugLog.errorSummary(error)))")
            }
        }
    }
}
