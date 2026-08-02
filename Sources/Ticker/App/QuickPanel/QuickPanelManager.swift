import AppKit
import SwiftUI

// MARK: - Ephemeral Conversation Model

/// A single turn in an ephemeral conversation
struct ConversationTurn: Equatable {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let content: String
    let contextIncluded: Bool  // True if this turn included captured context
    let saveContent: String?
    let aiReceipt: QuickPanelAIReceipt?

    init(
        role: Role,
        content: String,
        contextIncluded: Bool,
        saveContent: String? = nil,
        aiReceipt: QuickPanelAIReceipt? = nil
    ) {
        self.role = role
        self.content = content
        self.contextIncluded = contextIncluded
        self.saveContent = saveContent
        self.aiReceipt = aiReceipt
    }
}

struct QuickPanelAIReceipt: Equatable {
    let streamId: UUID
    let requestId: String
    let model: String?
    let userInput: String
    let sourceManifest: String
    let responseRaw: String
}

/// In-memory ephemeral conversation state (not persisted)
struct EphemeralConversation: Equatable {
    var isStreaming: Bool = false
    var currentResponse: String = ""
    var turns: [ConversationTurn] = []

    var isActive: Bool {
        !turns.isEmpty || isStreaming
    }

    mutating func clear() {
        isStreaming = false
        currentResponse = ""
        turns = []
    }

    mutating func discardStreamingTurn() {
        guard isStreaming else { return }
        isStreaming = false
        currentResponse = ""
        if turns.last?.role == .user {
            turns.removeLast()
        }
    }
}

struct QuickPanelLocalSelectionProvider {
    var pdfSelection: @MainActor () -> String? = { nil }
    var editorSelection: @MainActor () async -> String? = { nil }

    @MainActor
    func selectedText() async -> String? {
        if let pdfText = Self.nonEmptyTrimmed(pdfSelection()) {
            return pdfText
        }

        return Self.nonEmptyTrimmed(await editorSelection())
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum QuickPanelStatusAction: Equatable {
    case openAccessibilitySettings
}

struct QuickPanelStatus: Equatable {
    enum Tone: Equatable {
        case info
        case warning
    }

    let message: String
    let tone: Tone
    let action: QuickPanelStatusAction?

    static func selectionCaptureStatus(
        for outcome: SelectionCaptureOutcome
    ) -> QuickPanelStatus? {
        switch outcome {
        case .noPermission:
            return QuickPanelStatus(
                message: "Grant Accessibility permission to capture text selections",
                tone: .warning,
                action: .openAccessibilitySettings
            )
        case .stalePermission:
            return QuickPanelStatus(
                message: "Accessibility permission is stale — remove Ticker from the list and re-add it",
                tone: .warning,
                action: .openAccessibilitySettings
            )
        case .notAttempted, .internalApp, .ax, .axHinted, .clipboard, .emptyExternal:
            return nil
        }
    }
}

/// Manages the Quick Panel lifecycle, positioning, and state
/// Coordinates between services (cursor, selection) and the panel window
@MainActor
final class QuickPanelManager: ObservableObject {

    struct StreamingGeneration {
        private(set) var current = 0

        mutating func begin() -> Int {
            current += 1
            return current
        }

        mutating func invalidate() {
            current += 1
        }

        func owns(_ generation: Int) -> Bool {
            generation == current
        }
    }

    // MARK: - Published State

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var context: QuickPanelContext?
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var status: QuickPanelStatus?  // Temporary feedback and capture status.
    @Published private(set) var saveConfirmation: String?
    @Published var ephemeralConversation = EphemeralConversation()

    // Stream selection
    @Published private(set) var availableStreams: [StreamSummary] = []
    @Published var selectedStreamId: UUID?

    // MARK: - Services

    private let cursorService: CursorPositionService
    private let selectionService: SelectionReaderService
    private var localSelectionProvider = QuickPanelLocalSelectionProvider()
    private weak var persistence: PersistenceService?
    private weak var bridgeService: BridgeService?
    private var assetService: AssetService?
    private weak var orchestrator: AIOrchestrator?
    private let aiOperations: AIOperationRegistry

    // MARK: - Streaming Task

    private var streamingTask: Task<Void, Never>?
    private var streamingGeneration = StreamingGeneration()

    // MARK: - Height Management

    private var targetHeight: CGFloat = QuickPanelWindow.minHeight
    private var heightDebounceTimer: Timer?
    private var isAnimatingHeight: Bool = false

    // MARK: - Window

    private var panel: QuickPanelWindow?
    private var hostingView: NSHostingView<QuickPanelView>?
    private var currentAppearance: NSAppearance?  // Stored to apply when panel is created
    private var presentationGeneration: Int = 0
    private var preserveInputOnNextShow = false

    // MARK: - Initialization

    init(
        persistence: PersistenceService? = nil,
        bridgeService: BridgeService? = nil,
        aiOperations: AIOperationRegistry = AIOperationRegistry()
    ) {
        let cursor = CursorPositionService()
        self.cursorService = cursor
        self.selectionService = SelectionReaderService(cursorService: cursor)
        self.persistence = persistence
        self.bridgeService = bridgeService
        self.aiOperations = aiOperations
        connectAIOperationsToBridge()
    }

    deinit {
        streamingTask?.cancel()
        aiOperations.cancelAll()
    }

    /// Configure services after initialization (for dependency injection)
    func configure(
        persistence: PersistenceService,
        bridgeService: BridgeService,
        assetService: AssetService? = nil,
        orchestrator: AIOrchestrator? = nil
    ) {
        self.persistence = persistence
        self.bridgeService = bridgeService
        self.assetService = assetService ?? AssetService()
        self.orchestrator = orchestrator
        connectAIOperationsToBridge()
    }

    private func connectAIOperationsToBridge() {
        aiOperations.onChange = { [weak bridgeService] operation in
            var payload: [String: AnyCodable] = [
                "requestId": AnyCodable(operation.requestId),
                "streamId": AnyCodable(operation.streamId.uuidString),
                "verb": AnyCodable(operation.verb),
                "origin": AnyCodable(operation.origin),
                "state": AnyCodable(operation.state.rawValue)
            ]
            if let message = operation.message {
                payload["message"] = AnyCodable(message)
            }
            bridgeService?.send(BridgeMessage(
                type: "aiOperationChanged",
                payload: payload
            ))
        }
    }

    func configure(container: ServiceContainer) {
        guard let persistence = container.persistence else { return }
        configure(
            persistence: persistence,
            bridgeService: container.bridgeService,
            assetService: container.assetService,
            orchestrator: container.orchestrator
        )
    }

    func configureLocalSelectionProvider(_ provider: QuickPanelLocalSelectionProvider) {
        localSelectionProvider = provider
    }

    // MARK: - Public API

    /// Toggle the quick panel
    func toggle() {
        Task { @MainActor in
            await toggleAfterCapturingContext()
        }
    }

    private func toggleAfterCapturingContext() async {
        // Capture context BEFORE we steal focus
        let capturedContext = await buildContextForQuickPanelToggle()
        logCapturedContext(capturedContext)

        if isVisible {
            // Check if there's a new selection
            let hasNewSelection = capturedContext.contextText != nil &&
                capturedContext.contextText != context?.contextText

            if hasNewSelection {
                // Update context in place without discarding a note already in flight.
                self.context = capturedContext
                resetState(clearInput: false)
            } else {
                // Same selection or no selection - toggle off
                hide(preservingInput: true)
            }
            return
        }

        // Panel is hidden - show it
        show(with: capturedContext, showAccessibilityWarning: true)
    }

    private func buildContextForQuickPanelToggle() async -> QuickPanelContext {
        let activeBundleId = selectionService.getActiveAppBundleId()
        let appBundleId = Bundle.main.bundleIdentifier
        let selectionResult = await SelectionReaderService.resolveSelectedTextWithOutcome(
            activeBundleId: activeBundleId,
            currentBundleId: appBundleId,
            localSelection: { [localSelectionProvider] in
                await localSelectionProvider.selectedText()
            },
            externalSelection: { [selectionService] in
                selectionService.captureSelectedText()
            }
        )

        return selectionService.buildContext(
            selectedText: selectionResult.text,
            selectionCaptureOutcome: selectionResult.outcome,
            readSelectionFromAX: false,
            panelSize: currentPanelSizeForPositioning()
        )
    }

    /// Show the quick panel with specific context
    private func show(with capturedContext: QuickPanelContext, showAccessibilityWarning: Bool) {
        presentationGeneration += 1
        self.context = capturedContext
        resetState(clearInput: !preserveInputOnNextShow)
        preserveInputOnNextShow = false

        // Load available streams for picker
        loadAvailableStreams()

        if showAccessibilityWarning && !capturedContext.hasSelection && !capturedContext.isClipboardTextContext {
            status = QuickPanelStatus.selectionCaptureStatus(
                for: capturedContext.selectionCaptureOutcome
            )
        }

        // Create panel if needed
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        heightDebounceTimer?.invalidate()
        heightDebounceTimer = nil

        // Reset transient SwiftUI state and size the hidden panel before it is ordered onscreen.
        NotificationCenter.default.post(name: .quickPanelWillShow, object: nil)

        // Position at captured location
        panel.position(at: capturedContext.panelPosition)
        preparePanelHeightForPresentation()

        // Show panel without bringing main window forward
        isVisible = true
        panel.fadeIn()
        panel.makeKey()
        NotificationCenter.default.post(name: .quickPanelDidShow, object: nil)
    }

    /// Hide the quick panel
    func hide(preservingInput: Bool = false, fadeDuration: TimeInterval = 0.08) {
        presentationGeneration += 1
        let generation = presentationGeneration
        cancelStreaming(restoringPrompt: preservingInput)
        let keepInput = preservingInput && !inputText.isEmpty
        preserveInputOnNextShow = keepInput
        heightDebounceTimer?.invalidate()
        heightDebounceTimer = nil
        isVisible = false

        let finishHide = { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.resetState(clearInput: !keepInput)
            self.context = nil
            self.status = nil
        }

        guard let panel, panel.isVisible else {
            finishHide()
            return
        }

        panel.fadeOut(duration: fadeDuration, completion: finishHide)
        // Note: ephemeralConversation is intentionally preserved so user can re-reference
    }

    /// Cancel any active streaming task
    private func cancelStreaming(restoringPrompt: Bool = false) {
        let interruptedPrompt = restoringPrompt ? ephemeralConversation.turns.last.flatMap { turn in
            turn.role == .user ? turn.content : nil
        } : nil
        streamingGeneration.invalidate()
        streamingTask?.cancel()
        streamingTask = nil
        ephemeralConversation.discardStreamingTurn()
        if inputText.isEmpty, let interruptedPrompt {
            inputText = interruptedPrompt
        }
    }

    /// Reset state for new session
    private func resetState(clearInput: Bool = true) {
        if clearInput {
            inputText = ""
        }
        isLoading = false
        error = nil
        status = nil
        saveConfirmation = nil
    }

    private func logCapturedContext(_ capturedContext: QuickPanelContext) {
        let contextTextLength = capturedContext.contextText?.count ?? 0
        DebugLog.log(
            "[QuickPanel] toggle captured context " +
            "axTrusted=\(cursorService.hasAccessibilityPermission) " +
            "hasSelection=\(capturedContext.hasSelection) " +
            "isClipboardText=\(capturedContext.isClipboardTextContext) " +
            "contextTextLength=\(contextTextLength) " +
            "hasImage=\(capturedContext.hasImage) " +
            "activeApp=\(capturedContext.activeApp ?? "unknown")"
        )
    }

    /// Update panel appearance (light/dark mode)
    func updateAppearance(_ appearance: NSAppearance?) {
        currentAppearance = appearance
        panel?.appearance = appearance
    }

    // MARK: - Input Handling

    /// Handle Enter key - add content to stream
    func handleEnter() async {
        await addToStream()
    }

    /// Handle Cmd+Enter - add content and trigger AI
    func handleCmdEnter() async {
        await addToStream(triggerDocumentAI: true)
    }

    /// Handle Option+Enter - ephemeral AI conversation (not saved)
    func handleOptionEnter() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        guard let orchestrator = orchestrator else {
            error = "AI not configured"
            return
        }

        // Cancel any existing incomplete turn before starting another one.
        cancelStreaming()
        let generation = streamingGeneration.begin()

        // Build context for first turn only
        let isFirstTurn = ephemeralConversation.turns.isEmpty
        let contextForAI: String? = isFirstTurn ? context?.contextText : nil
        let queryImages: [String]
        do {
            queryImages = try Self.imageDataURLsForAI(
                isFirstTurn ? context?.clipboardImage : nil,
                using: assetService
            )
        } catch {
            self.error = error.localizedDescription
            return
        }
        let pickedStream = try? pickedStreamForAI()
        let streamIdForAI = pickedStream?.id
        let sourceScopeForAI = pickedStream?.sourceScope ?? .auto
        let requestId = UUID().uuidString
        let capturedContext = contextForAI ?? (queryImages.isEmpty ? "" : "[Image attached]")
        let userInput = "Selection:\n\(capturedContext)\n\nPrompt:\n\(query)"
        var responseRaw = ""
        var selectedModel: String?

        // Record user turn
        ephemeralConversation.turns.append(ConversationTurn(
            role: .user,
            content: query,
            contextIncluded: contextForAI != nil || !queryImages.isEmpty
        ))

        // Clear input, start streaming
        inputText = ""
        error = nil
        ephemeralConversation.isStreaming = true
        ephemeralConversation.currentResponse = ""

        // Build prior messages for multi-turn context
        // Drop the last turn (the one we just added) since that's the current query
        let priorCells: [[String: Any]] = ephemeralConversation.turns.dropLast().map { turn in
            [
                "type": turn.role == .user ? "text" : "aiResponse",
                "content": turn.content
            ]
        }

        // Stream response via AIOrchestrator in a cancellable task
        streamingTask = Task { [weak self] in
            await orchestrator.route(
                query: query,
                queryImages: queryImages,
                streamId: streamIdForAI,
                sourceScope: sourceScopeForAI,
                priorCells: priorCells,
                sourceContext: contextForAI.map {
                    SourceContext(text: $0, chunks: [], mode: .passthrough)
                },
                systemPromptOverride: Prompts.quickPanelChat,
                onChunk: { [weak self] chunk in
                    responseRaw += chunk
                    Task { @MainActor in
                        guard let self, self.streamingGeneration.owns(generation) else { return }
                        self.ephemeralConversation.currentResponse += chunk
                    }
                },
                onComplete: { [weak self] sourceContext in
                    Task { @MainActor in
                        guard let self, self.streamingGeneration.owns(generation) else { return }
                        // Record assistant turn with completed response
                        let manifest = DocumentAICitationManifest.entries(from: sourceContext) ?? []
                        let displayContent = CitationMarkerSwap.swap(responseRaw, manifest: manifest, mode: .plainLabel)
                        let saveContent = CitationMarkerSwap.swap(responseRaw, manifest: manifest, mode: .markdownLink)
                        let receipt = streamIdForAI.map {
                            QuickPanelAIReceipt(
                                streamId: $0,
                                requestId: requestId,
                                model: selectedModel,
                                userInput: userInput,
                                sourceManifest: DocumentAICitationManifest.jsonString(from: sourceContext),
                                responseRaw: responseRaw
                            )
                        }
                        self.ephemeralConversation.turns.append(ConversationTurn(
                            role: .assistant,
                            content: displayContent,
                            contextIncluded: false,
                            saveContent: saveContent,
                            aiReceipt: receipt
                        ))
                        self.ephemeralConversation.isStreaming = false
                        self.ephemeralConversation.currentResponse = ""
                        self.streamingTask = nil
                        self.streamingGeneration.invalidate()
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        guard let self, self.streamingGeneration.owns(generation) else { return }
                        self.error = err.localizedDescription
                        self.ephemeralConversation.discardStreamingTurn()
                        self.streamingTask = nil
                        self.streamingGeneration.invalidate()
                    }
                },
                onModelSelected: { model in
                    selectedModel = model
                }
            )
        }
    }

    /// Handle Escape key
    func handleEscape() {
        if ephemeralConversation.isStreaming {
            cancelStreaming(restoringPrompt: true)
            return
        }
        hide(preservingInput: true)
    }

    /// Clear attached context
    func clearContext() {
        context = nil
    }

    func performStatusAction(_ action: QuickPanelStatusAction) {
        switch action {
        case .openAccessibilitySettings:
            if !SystemSettingsOpener.openPrivacyPane(.accessibility) {
                cursorService.requestAccessibilityPermission()
            }
        }
    }

    func clearEphemeralConversation() {
        cancelStreaming()
        ephemeralConversation.clear()
    }

    // MARK: - Markdown Capture

    /// Add captured content and/or input to the active stream
    private func addToStream(triggerDocumentAI: Bool = false) async {
        guard !isLoading else { return }
        guard let persistence = persistence else {
            error = "Persistence not configured"
            return
        }

        let hasContext = context?.hasContext == true
        let prompt = nonEmptyTrimmed(inputText)
        let hasInput = prompt != nil

        // Must have something to add
        guard hasContext || hasInput else {
            hide()
            return
        }

        isLoading = true
        error = nil

        do {
            // Get target stream (may create new one)
            let (streamId, isNewStream) = try getTargetStreamId()
            let fragment = try buildMarkdownFragment(streamId: streamId)
            let spans = QuickPanelMarkdownFormatter.captureSpans(
                context: context,
                fragment: fragment,
                streamId: streamId
            )
            let result = try persistence.appendExternal(
                appendId: UUID().uuidString,
                streamId: streamId,
                fragment: fragment,
                spans: spans
            )
            notifyFrontend(
                streamId: streamId,
                result: result,
                isNewStream: isNewStream
            )

            let aiPrompt = triggerDocumentAI ? prompt : nil
            let orchestratorForAI = orchestrator
            let aiRequestId = aiPrompt.map { _ in
                aiOperations.begin(streamId: streamId, verb: "develop", origin: "quickPanel")
            }
            var documentMarkdownForAI: String?
            var queryImagesForAI: [String] = []
            var aiStartupError: String?

            if let aiRequestId {
                aiOperations.transition(aiRequestId, to: .preparing)
                if orchestratorForAI == nil {
                    aiStartupError = "AI is not configured"
                } else {
                    do {
                        documentMarkdownForAI = try persistence.loadOrCreateStreamDocument(streamId: streamId).markdown
                    } catch {
                        aiStartupError = "Could not load document context"
                        DebugLog.log("[QuickPanel] Failed to load document context for AI (\(DebugLog.errorSummary(error)))")
                    }

                    do {
                        queryImagesForAI = try Self.imageDataURLsForAI(
                            context?.clipboardImage,
                            using: assetService
                        )
                    } catch {
                        documentMarkdownForAI = nil
                        aiStartupError = error.localizedDescription
                        DebugLog.log("[QuickPanel] Failed to prepare attached image for AI (\(DebugLog.errorSummary(error)))")
                    }
                }
            }

            isLoading = false
            confirmSaveAndHide(
                to: streamId,
                fallbackDestination: isNewStream ? "Untitled" : nil,
                developing: triggerDocumentAI
            )

            if let aiPrompt, let aiRequestId {
                if let orchestratorForAI, let documentMarkdownForAI {
                    startDocumentAI(
                        requestId: aiRequestId,
                        streamId: streamId,
                        prompt: aiPrompt,
                        documentMarkdown: documentMarkdownForAI,
                        queryImages: queryImagesForAI,
                        persistence: persistence,
                        orchestrator: orchestratorForAI
                    )
                } else {
                    aiOperations.transition(
                        aiRequestId,
                        to: .failed,
                        message: quickPanelAIErrorMessage(summary: aiStartupError ?? "AI request could not start")
                    )
                }
            }
            return

        } catch {
            self.error = error.localizedDescription
            DebugLog.log("[QuickPanel] Error adding to stream (\(DebugLog.errorSummary(error)))")
        }

        isLoading = false
    }

    func saveConversationMessage(_ turn: ConversationTurn) -> Bool {
        guard let persistence = persistence else {
            error = "Persistence not configured"
            return false
        }

        let message = turn.saveContent ?? turn.content
        guard let fragment = nonEmptyTrimmed(message) else { return false }

        do {
            if let receipt = turn.aiReceipt {
                let didSave = appendQuickPanelAIFragment(
                    streamId: receipt.streamId,
                    fragment: fragment,
                    persistence: persistence,
                    requestId: receipt.requestId,
                    model: receipt.model,
                    userInput: receipt.userInput,
                    sourceManifest: receipt.sourceManifest,
                    responseRaw: receipt.responseRaw
                )
                if didSave {
                    announceSave(to: receipt.streamId)
                } else {
                    error = "The answer could not be saved"
                }
                return didSave
            }

            let (streamId, isNewStream) = try getTargetStreamId()
            let result = try persistence.appendExternal(
                appendId: UUID().uuidString,
                streamId: streamId,
                fragment: fragment
            )
            notifyFrontend(
                streamId: streamId,
                result: result,
                isNewStream: isNewStream
            )
            announceSave(to: streamId)
            return true
        } catch {
            self.error = error.localizedDescription
            DebugLog.log("[QuickPanel] Error saving conversation message (\(DebugLog.errorSummary(error)))")
            return false
        }
    }

    private func pickedStreamForAI() throws -> Stream? {
        guard let persistence = persistence else {
            throw QuickPanelError.persistenceNotConfigured
        }

        if let selectedStreamId, let stream = try persistence.loadStream(id: selectedStreamId) {
            return stream
        }

        if let recentStreamId = try persistence.getRecentlyModifiedStreamId() {
            return try persistence.loadStream(id: recentStreamId)
        }

        return nil
    }

    /// Load available streams for the picker
    func loadAvailableStreams() {
        guard let persistence = persistence else { return }
        do {
            availableStreams = try persistence.loadStreamSummaries()
            if let selectedStreamId,
               !availableStreams.contains(where: { $0.id == selectedStreamId }) {
                self.selectedStreamId = nil
            }
            if selectedStreamId == nil, let first = availableStreams.first {
                selectedStreamId = first.id
            }
        } catch {
            DebugLog.log("[QuickPanel] Failed to load streams (\(DebugLog.errorSummary(error)))")
        }
    }

    /// Create a new stream and select it
    func createAndSelectNewStream() {
        guard let persistence = persistence else { return }
        do {
            let newStream = Stream(title: "Untitled")
            try persistence.saveStream(newStream)
            selectedStreamId = newStream.id
            // Reload to include the new stream
            loadAvailableStreams()

            // Notify React frontend to reload its stream list
            bridgeService?.send(BridgeMessage(
                type: "streamsChanged",
                payload: [:]
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Get the target stream ID (selected, most recently modified, or create new)
    /// Returns (streamId, isNewStream) tuple
    private func getTargetStreamId() throws -> (UUID, Bool) {
        guard let persistence = persistence else {
            throw QuickPanelError.persistenceNotConfigured
        }

        if let selectedId = selectedStreamId,
           try persistence.loadStream(id: selectedId) != nil {
            return (selectedId, false)
        }
        selectedStreamId = nil

        // Fall back to most recently modified stream
        if let recentStreamId = try persistence.getRecentlyModifiedStreamId() {
            return (recentStreamId, false)
        }

        // No streams exist - create a new one
        let newStream = Stream(title: "Untitled")
        try persistence.saveStream(newStream)

        return (newStream.id, true)
    }

    private func buildMarkdownFragment(streamId: UUID) throws -> String {
        try QuickPanelMarkdownFormatter.buildFragment(
            context: context,
            inputText: inputText
        ) { imageData in
            guard let assetService = assetService else {
                throw QuickPanelError.assetServiceNotConfigured
            }

            let relativePath = try assetService.saveImage(data: imageData, streamId: streamId)
            return "![capture](ticker-asset:///\(relativePath))"
        }
    }

    private func nonEmptyTrimmed(_ text: String?) -> String? {
        QuickPanelMarkdownFormatter.nonEmptyTrimmed(text)
    }

    static func saveConfirmationMessage(destination: String?, developing: Bool) -> String {
        let trimmed = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = trimmed.flatMap { $0.isEmpty ? nil : "Saved to \($0)" } ?? "Saved"
        return developing ? "\(saved) · developing…" : saved
    }

    private func destinationTitle(for streamId: UUID) -> String? {
        availableStreams.first(where: { $0.id == streamId })?.title
    }

    private func confirmSaveAndHide(
        to streamId: UUID,
        fallbackDestination: String?,
        developing: Bool
    ) {
        let message = Self.saveConfirmationMessage(
            destination: destinationTitle(for: streamId) ?? fallbackDestination,
            developing: developing
        )
        saveConfirmation = message
        announce(message)
        hide(fadeDuration: 0.18)
    }

    private func announceSave(to streamId: UUID) {
        announce(Self.saveConfirmationMessage(
            destination: destinationTitle(for: streamId),
            developing: false
        ))
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func startDocumentAI(
        requestId: String,
        streamId: UUID,
        prompt: String,
        documentMarkdown: String,
        queryImages: [String],
        persistence: PersistenceService,
        orchestrator: AIOrchestrator
    ) {
        var responseMarkdown = ""
        var selectedModel: String?

        let task = Task { [weak self] in
            await orchestrator.route(
                query: prompt,
                queryImages: queryImages,
                streamId: nil,
                priorCells: [],
                sourceContext: SourceContext(text: documentMarkdown, chunks: [], mode: .passthrough),
                includeHeading: false,
                onChunk: { [weak self] chunk in
                    responseMarkdown += chunk
                    Task { @MainActor in
                        self?.aiOperations.transition(requestId, to: .generating)
                    }
                },
                onComplete: { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.aiOperations.isActive(requestId) else { return }

                        let fragment = responseMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        if fragment.isEmpty {
                            self.aiOperations.transition(
                                requestId,
                                to: .failed,
                                message: self.quickPanelAIErrorMessage(summary: "AI returned an empty response")
                            )
                        } else {
                            self.aiOperations.transition(requestId, to: .saving)
                            let didSave = self.appendQuickPanelAIFragment(
                                streamId: streamId,
                                fragment: fragment,
                                persistence: persistence,
                                requestId: requestId,
                                model: selectedModel,
                                prompt: prompt,
                                documentMarkdown: documentMarkdown
                            )
                            self.aiOperations.transition(
                                requestId,
                                to: didSave ? .succeeded : .failed,
                                message: didSave ? nil : "Quick Panel AI answer could not be saved. Try again."
                            )
                        }
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.aiOperations.isActive(requestId) else { return }

                        self.aiOperations.transition(
                            requestId,
                            to: .failed,
                            message: self.quickPanelAIErrorMessage(summary: error.localizedDescription)
                        )
                    }
                },
                onModelSelected: { model in
                    selectedModel = model
                }
            )
        }
        aiOperations.attach(task, to: requestId)
    }

    static func imageDataURLsForAI(_ imageData: Data?, using assetService: AssetService?) throws -> [String] {
        guard let imageData else { return [] }
        guard let dataURL = assetService?.imageToDataURL(imageData) else {
            throw QuickPanelError.imagePreparationFailed
        }
        return [dataURL]
    }

    @discardableResult
    func appendQuickPanelAIFragment(
        streamId: UUID,
        fragment: String,
        persistence: PersistenceService,
        requestId: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        documentMarkdown: String? = nil,
        userInput: String? = nil,
        sourceManifest: String = "[]",
        responseRaw: String? = nil
    ) -> Bool {
        do {
            let spans = requestId.map { id in
                [
                    ProvenanceSpan(
                        streamId: streamId,
                        start: 0,
                        end: UTF16Offsets.utf16Length(fragment),
                        origin: "ai",
                        requestId: id,
                        meta: QuickPanelMarkdownFormatter.metadataJSON([
                            "model": model ?? "unknown",
                            "verb": "develop"
                        ]),
                        textHash: FNV1a.hash(fragment)
                    )
                ]
            } ?? []
            let exchange = requestId.map {
                AIExchange(
                    requestId: $0,
                    streamId: streamId,
                    verb: "develop",
                    userInput: userInput ?? "Selection:\n\(documentMarkdown ?? "")\n\nPrompt:\n\(prompt ?? "")",
                    sourceManifest: sourceManifest,
                    responseRaw: responseRaw ?? fragment,
                    model: model
                )
            }
            let result = try persistence.appendExternal(
                appendId: requestId ?? UUID().uuidString,
                streamId: streamId,
                fragment: fragment,
                spans: spans,
                exchange: exchange
            )
            notifyFrontend(
                streamId: streamId,
                result: result,
                source: "quickPanelAI"
            )
            return true
        } catch {
            DebugLog.log("[QuickPanel] Failed to append AI response (\(DebugLog.errorSummary(error)))")
            return false
        }
    }

    private func quickPanelAIErrorMessage(summary: String) -> String {
        let compact = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = compact.isEmpty ? "Unknown error" : compact
        let shortened = fallback.count > 180 ? "\(fallback.prefix(177))..." : fallback
        return "AI request failed: \(shortened)"
    }

    /// Notify the React frontend about document appends.
    private func notifyFrontend(
        streamId: UUID,
        result: ExternalAppendResult,
        isNewStream: Bool = false,
        source: String = "quickPanel"
    ) {
        guard let bridgeService = bridgeService else { return }
        bridgeService.send(StreamCodec.externalAppendMessage(
            streamId: streamId,
            result: result,
            isNewStream: isNewStream,
            source: source
        ))
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let newPanel = QuickPanelWindow()

        newPanel.onDismiss = { [weak self] in
            self?.hide(preservingInput: true)
        }
        newPanel.onEscape = { [weak self] in
            self?.handleEscape()
        }

        let view = QuickPanelView(manager: self)
        let hosting = NSHostingView(rootView: view)

        newPanel.setContentSize(NSSize(
            width: QuickPanelWindow.defaultWidth,
            height: QuickPanelWindow.minHeight
        ))

        hosting.frame = newPanel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]

        newPanel.contentView?.addSubview(hosting)

        // Apply stored appearance (light/dark mode)
        if let appearance = currentAppearance {
            newPanel.appearance = appearance
        }

        self.panel = newPanel
        self.hostingView = hosting
    }

    // MARK: - Height Management

    private func currentPanelSizeForPositioning() -> CGSize {
        CGSize(
            width: QuickPanelWindow.defaultWidth,
            height: max(panel?.frame.height ?? targetHeight, QuickPanelWindow.minHeight)
        )
    }

    private func preparePanelHeightForPresentation() {
        guard let hostingView, let panel else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = hostingView.fittingSize.height
        guard fittingHeight.isFinite, fittingHeight > 0 else { return }

        targetHeight = max(QuickPanelWindow.minHeight, min(fittingHeight, maxAllowedPanelHeight()))
        panel.resize(toHeight: targetHeight, animated: false)
    }

    private func maxAllowedPanelHeight() -> CGFloat {
        let visibleHeight = (panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? QuickPanelWindow.maxHeight
        return max(QuickPanelWindow.minHeight, min(QuickPanelWindow.maxHeight, visibleHeight - 16))
    }

    /// Called by SwiftUI when content height changes
    func contentHeightChanged(_ height: CGFloat) {
        guard isVisible else { return }
        contentHeightChanged(height, animatedGrowth: false)
    }

    private func contentHeightChanged(_ height: CGFloat, animatedGrowth: Bool) {
        let clampedHeight = max(QuickPanelWindow.minHeight, min(height, maxAllowedPanelHeight()))

        // Skip if height hasn't meaningfully changed (reduces timer churn during streaming)
        guard abs(targetHeight - clampedHeight) > 2 else { return }
        targetHeight = clampedHeight

        let currentHeight = panel?.frame.height ?? QuickPanelWindow.minHeight
        if clampedHeight > currentHeight + 2 {
            heightDebounceTimer?.invalidate()
            applyHeightUpdate(animated: animatedGrowth)
            return
        }

        heightDebounceTimer?.invalidate()
        // Debounce shrink/steady-state changes to batch rapid content updates during streaming.
        heightDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.applyHeightUpdate(animated: true)
            }
        }
    }

    private func applyHeightUpdate(animated: Bool) {
        guard isVisible, let panel = panel else { return }

        // Skip if already animating - the completion handler will check if another update is needed
        guard !isAnimatingHeight else { return }

        let currentHeight = panel.frame.height
        // Require meaningful difference to animate (avoid micro-adjustments)
        guard abs(currentHeight - targetHeight) > 4 else { return }

        isAnimatingHeight = true
        panel.resize(toHeight: targetHeight, animated: animated) { [weak self] in
            guard let self = self else { return }
            self.isAnimatingHeight = false

            // Check if height changed during animation - if so, schedule another update
            let finalHeight = self.panel?.frame.height ?? 0
            if self.isVisible, abs(finalHeight - self.targetHeight) > 4 {
                self.applyHeightUpdate(animated: true)
            }
        }
    }
}

enum QuickPanelMarkdownFormatter {
    static func buildFragment(
        context: QuickPanelContext?,
        inputText: String,
        imageMarkdown: (Data) throws -> String
    ) throws -> String {
        var blocks: [String] = []

        if let context {
            if let contextText = nonEmptyTrimmed(context.contextText) {
                blocks.append(markdownBlockquote(contextText))

                if let source = sourceAttribution(for: context) {
                    blocks.append("*— \(escapeMarkdownEmphasis(source))*")
                }
            }

            if let imageData = context.clipboardImage {
                blocks.append(try imageMarkdown(imageData))
            }
        }

        if let input = nonEmptyTrimmed(inputText) {
            blocks.append(input)
        }

        return blocks.joined(separator: "\n\n")
    }

    static func captureSpans(context: QuickPanelContext?, fragment: String, streamId: UUID) -> [ProvenanceSpan] {
        guard let context,
              let contextText = nonEmptyTrimmed(context.contextText) else {
            return []
        }

        var blocks = [markdownBlockquote(contextText)]
        if let source = sourceAttribution(for: context) {
            blocks.append("*— \(escapeMarkdownEmphasis(source))*")
        }
        let capturedMarkdown = blocks.joined(separator: "\n\n")
        guard fragment.hasPrefix(capturedMarkdown) else { return [] }

        return [
            ProvenanceSpan(
                streamId: streamId,
                start: 0,
                end: UTF16Offsets.utf16Length(capturedMarkdown),
                origin: "capture",
                meta: metadataJSON(["sourceApp": nonEmptyTrimmed(context.activeApp) ?? "Unknown"]),
                textHash: FNV1a.hash(capturedMarkdown)
            )
        ]
    }

    static func metadataJSON(_ values: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func escapeMarkdownEmphasis(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func markdownBlockquote(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.newlines)
            .map { line in
                line.isEmpty ? ">" : "> \(line)"
            }
            .joined(separator: "\n")
    }

    private static func sourceAttribution(for context: QuickPanelContext) -> String? {
        let app = nonEmptyTrimmed(context.activeApp)
        let title = nonEmptyTrimmed(context.windowTitle).map {
            SourceShortTitle.derive(displayName: $0)
        }

        switch (app, title) {
        case let (app?, title?):
            return "\(app) — \(title)"
        case let (app?, nil):
            return app
        case let (nil, title?):
            return title
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - Errors

enum QuickPanelError: Error, LocalizedError {
    case persistenceNotConfigured
    case assetServiceNotConfigured
    case imagePreparationFailed

    var errorDescription: String? {
        switch self {
        case .persistenceNotConfigured:
            return "Database not configured"
        case .assetServiceNotConfigured:
            return "Asset storage not configured"
        case .imagePreparationFailed:
            return "Attached image could not be prepared for AI"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let quickPanelWillShow = Notification.Name("QuickPanelWillShow")
    static let quickPanelDidShow = Notification.Name("QuickPanelDidShow")
}
