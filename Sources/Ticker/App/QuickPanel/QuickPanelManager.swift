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
        case success
        case warning
    }

    let message: String
    let tone: Tone
    let action: QuickPanelStatusAction?

    static func selectionCaptureStatus(
        for outcome: SelectionCaptureOutcome,
        activeApp: String?
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
        case .emptyExternal:
            let appName = activeApp?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let appName, !appName.isEmpty {
                message = "No text selected in \(appName) — copy it (⌘C) and press ⌘L to attach."
            } else {
                message = "No text selected — copy it (⌘C) and press ⌘L to attach."
            }
            return QuickPanelStatus(
                message: message,
                tone: .info,
                action: nil
            )
        case .notAttempted, .internalApp, .ax, .axHinted, .clipboard:
            return nil
        }
    }
}

/// Manages the Quick Panel lifecycle, positioning, and state
/// Coordinates between services (cursor, selection) and the panel window
@MainActor
final class QuickPanelManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var context: QuickPanelContext?
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var status: QuickPanelStatus?  // Temporary feedback and capture status.
    @Published private(set) var isInputSaveFeedbackActive: Bool = false
    @Published private(set) var isStreamPickerSaveFeedbackActive: Bool = false
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

    // MARK: - Streaming Task

    private var streamingTask: Task<Void, Never>?
    private var documentAITasks: [UUID: Task<Void, Never>] = [:]
    private var statusClearTask: Task<Void, Never>?
    private var saveFeedbackTask: Task<Void, Never>?
    private var isStreamingCancelled = false  // Explicit flag since nested Tasks don't inherit cancellation

    // MARK: - Height Management

    private var targetHeight: CGFloat = QuickPanelWindow.minHeight
    private var heightDebounceTimer: Timer?
    private var isAnimatingHeight: Bool = false

    // MARK: - Window

    private var panel: QuickPanelWindow?
    private var hostingView: NSHostingView<QuickPanelView>?
    private var currentAppearance: NSAppearance?  // Stored to apply when panel is created
    private var suppressedClipboardImageChangeCount: Int?
    private var suppressedClipboardTextChangeCount: Int?
    private var presentationGeneration: Int = 0

    // MARK: - Initialization

    init(
        persistence: PersistenceService? = nil,
        bridgeService: BridgeService? = nil
    ) {
        let cursor = CursorPositionService()
        self.cursorService = cursor
        self.selectionService = SelectionReaderService(cursorService: cursor)
        self.persistence = persistence
        self.bridgeService = bridgeService
    }

    deinit {
        streamingTask?.cancel()
        documentAITasks.values.forEach { $0.cancel() }
        statusClearTask?.cancel()
        saveFeedbackTask?.cancel()
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
        let capturedContext = contextRespectingDismissedClipboardText(
            contextRespectingDismissedClipboardImage(await buildContextForQuickPanelToggle())
        )
        logCapturedContext(capturedContext)

        if isVisible {
            // Check if there's a new selection
            let hasNewSelection = capturedContext.contextText != nil &&
                capturedContext.contextText != context?.contextText

            if hasNewSelection {
                // Update context in place, don't move the panel
                self.context = capturedContext
                resetState()
            } else {
                // Same selection or no selection - toggle off
                hide()
            }
            return
        }

        // Panel is hidden - show it
        show(with: capturedContext, showAccessibilityWarning: true)
    }

    private func buildContextForQuickPanelToggle() async -> QuickPanelContext {
        let activeBundleId = selectionService.getActiveAppBundleId()
        let appBundleId = Bundle.main.bundleIdentifier
        let clipboardTextCandidate = SelectionReaderService.recentClipboardTextCandidate()
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
            clipboardTextCandidate: clipboardTextCandidate,
            selectionCaptureOutcome: selectionResult.outcome,
            readSelectionFromAX: false,
            panelSize: currentPanelSizeForPositioning()
        )
    }

    /// Show after screenshot capture with status feedback
    func showAfterScreenshot() {
        if isVisible {
            hide()
        }
        var capturedContext = selectionService.buildContext()

        // Verify clipboard has image and update context
        if let imageData = ClipboardService.getImageData() {
            capturedContext = QuickPanelContext(
                selectedText: capturedContext.selectedText,
                activeApp: capturedContext.activeApp,
                windowTitle: capturedContext.windowTitle,
                panelPosition: capturedContext.panelPosition,
                clipboardImage: imageData,
                clipboardText: capturedContext.clipboardText,
                isScreenshot: true,
                selectionCaptureOutcome: capturedContext.selectionCaptureOutcome
            )
            // New explicit screenshot capture should always attach, even if a prior clipboard image
            // was manually dismissed from context.
            suppressedClipboardImageChangeCount = nil
        }

        show(with: capturedContext, showAccessibilityWarning: false)
    }

    /// Show the Quick Panel with an informational status message (no clipboard image attachment).
    /// Useful for explaining why a screenshot capture couldn't proceed (e.g., missing permissions).
    func showWithStatusMessage(_ message: String) {
        if isVisible {
            hide()
        }

        let capturedContext = selectionService.buildContext()
        // Avoid implicitly attaching any pre-existing clipboard image — this mode is informational.
        let contextWithoutClipboard = QuickPanelContext(
            selectedText: capturedContext.selectedText,
            activeApp: capturedContext.activeApp,
            windowTitle: capturedContext.windowTitle,
            panelPosition: capturedContext.panelPosition,
            clipboardImage: nil,
            clipboardText: nil,
            isScreenshot: false,
            selectionCaptureOutcome: capturedContext.selectionCaptureOutcome
        )

        show(with: contextWithoutClipboard, showAccessibilityWarning: false)
        showTimedStatusMessage(message, durationNanoseconds: 4_000_000_000)
    }

    /// Show the quick panel with specific context
    private func show(with capturedContext: QuickPanelContext, showAccessibilityWarning: Bool) {
        presentationGeneration += 1
        cancelFeedbackTasks()
        self.context = capturedContext
        resetState()

        // Load available streams for picker
        loadAvailableStreams()

        if showAccessibilityWarning && !capturedContext.hasSelection && !capturedContext.isClipboardTextContext {
            status = QuickPanelStatus.selectionCaptureStatus(
                for: capturedContext.selectionCaptureOutcome,
                activeApp: capturedContext.activeApp
            )
        }

        // Create panel if needed
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        heightDebounceTimer?.invalidate()
        targetHeight = QuickPanelWindow.minHeight
        panel.resetToMinHeight()

        // Position at captured location
        panel.position(at: capturedContext.panelPosition)

        // Show panel without bringing main window forward
        panel.fadeIn()
        panel.makeKey()

        isVisible = true

        // Post notification for input focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .quickPanelDidShow, object: nil)
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncHeightToContent(animated: false)
        }
    }

    /// Hide the quick panel
    func hide() {
        presentationGeneration += 1
        let generation = presentationGeneration
        cancelFeedbackTasks()
        // Cancel any in-flight streaming to avoid orphan AI calls
        cancelStreaming()

        isVisible = false

        let finishHide = { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.resetState()
            self.context = nil
            self.status = nil
        }

        guard let panel, panel.isVisible else {
            finishHide()
            return
        }

        panel.fadeOut(completion: finishHide)
        // Note: ephemeralConversation is intentionally preserved so user can re-reference
    }

    /// Cancel any active streaming task
    private func cancelStreaming() {
        isStreamingCancelled = true
        streamingTask?.cancel()
        streamingTask = nil
        ephemeralConversation.isStreaming = false
    }

    /// Reset state for new session
    private func resetState() {
        inputText = ""
        isLoading = false
        error = nil
        status = nil
        isInputSaveFeedbackActive = false
        isStreamPickerSaveFeedbackActive = false
    }

    private func cancelFeedbackTasks() {
        statusClearTask?.cancel()
        statusClearTask = nil
        saveFeedbackTask?.cancel()
        saveFeedbackTask = nil
    }

    private func showTimedStatusMessage(_ message: String, durationNanoseconds: UInt64) {
        statusClearTask?.cancel()
        isInputSaveFeedbackActive = false
        isStreamPickerSaveFeedbackActive = false
        let timedStatus = QuickPanelStatus(message: message, tone: .info, action: nil)
        status = timedStatus

        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.status == timedStatus else { return }
                self.status = nil
                self.statusClearTask = nil
            }
        }
    }

    private func showStreamPickerSaveFeedbackThenHide() {
        statusClearTask?.cancel()
        statusClearTask = nil
        saveFeedbackTask?.cancel()
        isInputSaveFeedbackActive = true
        isStreamPickerSaveFeedbackActive = true
        status = nil

        saveFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.hide()
            }
        }
    }

    private func flashStreamPickerSaveFeedback(durationNanoseconds: UInt64 = 600_000_000) {
        statusClearTask?.cancel()
        statusClearTask = nil
        isInputSaveFeedbackActive = false
        isStreamPickerSaveFeedbackActive = true
        status = nil

        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isInputSaveFeedbackActive else { return }
                self.isStreamPickerSaveFeedbackActive = false
                self.statusClearTask = nil
            }
        }
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

        // Cancel any existing streaming task
        streamingTask?.cancel()
        isStreamingCancelled = false  // Reset flag for new streaming session

        // Build context for first turn only
        let isFirstTurn = ephemeralConversation.turns.isEmpty
        let contextForAI: String? = isFirstTurn ? context?.contextText : nil
        let pickedStream = try? pickedStreamForAI()
        let streamIdForAI = pickedStream?.id
        let sourceScopeForAI = pickedStream?.sourceScope ?? .auto
        let requestId = UUID().uuidString
        let userInput = "Selection:\n\(contextForAI ?? "")\n\nPrompt:\n\(query)"
        var responseRaw = ""
        var selectedModel: String?

        // Record user turn
        ephemeralConversation.turns.append(ConversationTurn(
            role: .user,
            content: query,
            contextIncluded: contextForAI != nil
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
                streamId: streamIdForAI,
                sourceScope: sourceScopeForAI,
                priorCells: priorCells,
                sourceContext: contextForAI,
                systemPromptOverride: Prompts.quickPanelChat,
                onChunk: { [weak self] chunk in
                    responseRaw += chunk
                    Task { @MainActor in
                        guard let self = self, !self.isStreamingCancelled else { return }
                        self.ephemeralConversation.currentResponse += chunk
                    }
                },
                onComplete: { [weak self] sourceContext in
                    Task { @MainActor in
                        guard let self = self, !self.isStreamingCancelled else { return }
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
                    }
                },
                onError: { [weak self] err in
                    Task { @MainActor in
                        guard let self = self, !self.isStreamingCancelled else { return }
                        self.error = err.localizedDescription
                        self.ephemeralConversation.isStreaming = false
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
        // First priority: cancel streaming and clear ephemeral conversation if active
        if ephemeralConversation.isActive {
            cancelStreaming()
            ephemeralConversation.clear()
            return
        }

        if isInputSaveFeedbackActive {
            hide()
            return
        }

        // Second: clear input/context
        if !inputText.isEmpty || context?.hasContent == true {
            suppressDismissedClipboardContextIfNeeded()
            inputText = ""
            context = nil
            return
        }

        // Third: hide panel
        hide()
    }

    /// Clear attached context
    func clearContext() {
        suppressDismissedClipboardContextIfNeeded()
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

    private func suppressDismissedClipboardContextIfNeeded() {
        suppressDismissedClipboardImageIfNeeded()
        suppressDismissedClipboardTextIfNeeded()
    }

    /// Suppress reattaching the current clipboard image on Cmd+L until clipboard changes.
    private func suppressDismissedClipboardImageIfNeeded() {
        guard context?.hasImage == true else { return }
        suppressedClipboardImageChangeCount = ClipboardService.changeCount()
    }

    /// Suppress reattaching the current clipboard text on Cmd+L until clipboard changes.
    private func suppressDismissedClipboardTextIfNeeded() {
        guard context?.isClipboardTextContext == true else { return }
        suppressedClipboardTextChangeCount = ClipboardService.changeCount()
    }

    /// Applies explicit image-dismissal state to freshly captured context.
    private func contextRespectingDismissedClipboardImage(_ capturedContext: QuickPanelContext) -> QuickPanelContext {
        let currentClipboardChangeCount = ClipboardService.changeCount()

        if let suppressedCount = suppressedClipboardImageChangeCount,
           suppressedCount != currentClipboardChangeCount {
            suppressedClipboardImageChangeCount = nil
        }

        guard capturedContext.hasImage,
              suppressedClipboardImageChangeCount == currentClipboardChangeCount else {
            return capturedContext
        }

        return QuickPanelContext(
            selectedText: capturedContext.selectedText,
            activeApp: capturedContext.activeApp,
            windowTitle: capturedContext.windowTitle,
            panelPosition: capturedContext.panelPosition,
            clipboardImage: nil,
            clipboardText: capturedContext.clipboardText,
            isScreenshot: false,
            selectionCaptureOutcome: capturedContext.selectionCaptureOutcome
        )
    }

    /// Applies explicit text-dismissal state to freshly captured context.
    private func contextRespectingDismissedClipboardText(_ capturedContext: QuickPanelContext) -> QuickPanelContext {
        let currentClipboardChangeCount = ClipboardService.changeCount()
        return Self.contextRespectingDismissedClipboardText(
            capturedContext,
            suppressedChangeCount: &suppressedClipboardTextChangeCount,
            currentClipboardChangeCount: currentClipboardChangeCount
        )
    }

    static func contextRespectingDismissedClipboardText(
        _ capturedContext: QuickPanelContext,
        suppressedChangeCount: inout Int?,
        currentClipboardChangeCount: Int
    ) -> QuickPanelContext {
        if let suppressedCount = suppressedChangeCount,
           suppressedCount != currentClipboardChangeCount {
            suppressedChangeCount = nil
        }

        guard capturedContext.isClipboardTextContext,
              suppressedChangeCount == currentClipboardChangeCount else {
            return capturedContext
        }

        return QuickPanelContext(
            selectedText: capturedContext.selectedText,
            activeApp: capturedContext.activeApp,
            windowTitle: capturedContext.windowTitle,
            panelPosition: capturedContext.panelPosition,
            clipboardImage: capturedContext.clipboardImage,
            clipboardText: nil,
            isScreenshot: capturedContext.isScreenshot,
            selectionCaptureOutcome: capturedContext.selectionCaptureOutcome
        )
    }

    // MARK: - Markdown Capture

    /// Add captured content and/or input to the active stream
    private func addToStream(triggerDocumentAI: Bool = false) async {
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
            let result = try persistence.appendToStreamDocument(streamId: streamId, fragment: fragment, spans: spans)
            notifyFrontend(
                streamId: streamId,
                fragment: result.fragment,
                revision: result.revision,
                spans: result.spans,
                isNewStream: isNewStream
            )

            let aiPrompt = triggerDocumentAI ? prompt : nil
            let orchestratorForAI = orchestrator
            var documentMarkdownForAI: String?
            var aiStartupError: String?

            if aiPrompt != nil {
                if orchestratorForAI == nil {
                    aiStartupError = "AI is not configured"
                } else {
                    do {
                        documentMarkdownForAI = try persistence.loadOrCreateStreamDocument(streamId: streamId).markdown
                    } catch {
                        aiStartupError = "Could not load document context"
                        DebugLog.log("[QuickPanel] Failed to load document context for AI (\(DebugLog.errorSummary(error)))")
                    }
                }
            }

            isLoading = false
            showStreamPickerSaveFeedbackThenHide()

            if let aiPrompt {
                if let orchestratorForAI, let documentMarkdownForAI {
                    startDocumentAI(
                        streamId: streamId,
                        prompt: aiPrompt,
                        documentMarkdown: documentMarkdownForAI,
                        persistence: persistence,
                        orchestrator: orchestratorForAI
                    )
                } else {
                    appendQuickPanelAIError(
                        streamId: streamId,
                        summary: aiStartupError ?? "AI request could not start",
                        persistence: persistence
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

    func saveConversationMessage(_ turn: ConversationTurn) {
        guard let persistence = persistence else {
            error = "Persistence not configured"
            return
        }

        let message = turn.saveContent ?? turn.content
        guard let fragment = nonEmptyTrimmed(message) else { return }

        do {
            if let receipt = turn.aiReceipt {
                appendQuickPanelAIFragment(
                    streamId: receipt.streamId,
                    fragment: fragment,
                    persistence: persistence,
                    requestId: receipt.requestId,
                    model: receipt.model,
                    userInput: receipt.userInput,
                    sourceManifest: receipt.sourceManifest,
                    responseRaw: receipt.responseRaw
                )
                flashStreamPickerSaveFeedback()
                return
            }

            let (streamId, isNewStream) = try getTargetStreamId()
            let result = try persistence.appendToStreamDocument(streamId: streamId, fragment: fragment)
            notifyFrontend(
                streamId: streamId,
                fragment: result.fragment,
                revision: result.revision,
                spans: result.spans,
                isNewStream: isNewStream
            )
            flashStreamPickerSaveFeedback()
        } catch {
            self.error = error.localizedDescription
            DebugLog.log("[QuickPanel] Error saving conversation message (\(DebugLog.errorSummary(error)))")
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
            // Pre-select most recent if none selected
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

        // Use selected stream if set
        if let selectedId = selectedStreamId {
            return (selectedId, false)
        }

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

    private func startDocumentAI(
        streamId: UUID,
        prompt: String,
        documentMarkdown: String,
        persistence: PersistenceService,
        orchestrator: AIOrchestrator
    ) {
        let taskId = UUID()
        let requestId = taskId.uuidString
        var responseMarkdown = ""
        var selectedModel: String?

        // Tell the editor work is in flight so it can show presence at the
        // append point. Every terminal path below appends (answer or error
        // fragment), so streamDocumentAppended doubles as the "done" signal.
        bridgeService?.send(BridgeMessage(type: "quickPanelAIStarted", payload: [
            "streamId": AnyCodable(streamId.uuidString)
        ]))

        documentAITasks[taskId] = Task { [weak self] in
            await orchestrator.route(
                query: prompt,
                streamId: nil,
                priorCells: [],
                sourceContext: documentMarkdown,
                includeHeading: false,
                onChunk: { chunk in
                    responseMarkdown += chunk
                },
                onComplete: { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }

                        let fragment = responseMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        if fragment.isEmpty {
                            self.appendQuickPanelAIError(
                                streamId: streamId,
                                summary: "AI returned an empty response",
                                persistence: persistence
                            )
                        } else {
                            self.appendQuickPanelAIFragment(
                                streamId: streamId,
                                fragment: fragment,
                                persistence: persistence,
                                requestId: requestId,
                                model: selectedModel,
                                prompt: prompt,
                                documentMarkdown: documentMarkdown
                            )
                        }

                        self.documentAITasks[taskId] = nil
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }

                        self.appendQuickPanelAIError(
                            streamId: streamId,
                            summary: error.localizedDescription,
                            persistence: persistence
                        )
                        self.documentAITasks[taskId] = nil
                    }
                },
                onModelSelected: { model in
                    selectedModel = model
                }
            )
        }
    }

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
    ) {
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
            let result = try persistence.appendToStreamDocument(streamId: streamId, fragment: fragment, spans: spans)
            if let requestId {
                do {
                    try persistence.saveExchange(AIExchange(
                        requestId: requestId,
                        streamId: streamId,
                        verb: "develop",
                        userInput: userInput ?? "Selection:\n\(documentMarkdown ?? "")\n\nPrompt:\n\(prompt ?? "")",
                        sourceManifest: sourceManifest,
                        responseRaw: responseRaw ?? fragment,
                        model: model
                    ))
                } catch {
                    DebugLog.log("[QuickPanel] Failed to save AI exchange (\(DebugLog.errorSummary(error)))")
                }
            }
            notifyFrontend(
                streamId: streamId,
                fragment: result.fragment,
                revision: result.revision,
                spans: result.spans,
                source: "quickPanelAI"
            )
        } catch {
            DebugLog.log("[QuickPanel] Failed to append AI response (\(DebugLog.errorSummary(error)))")
        }
    }

    private func appendQuickPanelAIError(streamId: UUID, summary: String, persistence: PersistenceService) {
        appendQuickPanelAIFragment(
            streamId: streamId,
            fragment: quickPanelAIErrorFragment(summary: summary),
            persistence: persistence
        )
    }

    private func quickPanelAIErrorFragment(summary: String) -> String {
        let compact = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = compact.isEmpty ? "Unknown error" : compact
        let shortened = fallback.count > 180 ? "\(fallback.prefix(177))..." : fallback
        return "*AI request failed: \(QuickPanelMarkdownFormatter.escapeMarkdownEmphasis(shortened))*"
    }

    /// Notify the React frontend about document appends.
    private func notifyFrontend(
        streamId: UUID,
        fragment: String,
        revision: Int,
        spans: [ProvenanceSpan] = [],
        isNewStream: Bool = false,
        source: String = "quickPanel"
    ) {
        guard let bridgeService = bridgeService else { return }

        let payload: [String: AnyCodable] = [
            "streamId": AnyCodable(streamId.uuidString),
            "fragment": AnyCodable(fragment),
            "revision": AnyCodable(revision),
            "isNewStream": AnyCodable(isNewStream),
            "source": AnyCodable(source),
            "spans": AnyCodable(StreamCodec.encodeSpans(spans))
        ]

        bridgeService.send(BridgeMessage(type: "streamDocumentAppended", payload: payload))
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let newPanel = QuickPanelWindow()

        newPanel.onDismiss = { [weak self] in
            self?.hide()
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

    private func syncHeightToContent(animated: Bool) {
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = hostingView.fittingSize.height
        guard fittingHeight.isFinite, fittingHeight > 0 else { return }
        contentHeightChanged(fittingHeight, animatedGrowth: animated)
    }

    private func maxAllowedPanelHeight() -> CGFloat {
        let visibleHeight = (panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? QuickPanelWindow.maxHeight
        return max(QuickPanelWindow.minHeight, min(QuickPanelWindow.maxHeight, visibleHeight - 16))
    }

    /// Called by SwiftUI when content height changes
    func contentHeightChanged(_ height: CGFloat) {
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
        guard let panel = panel else { return }

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
            if abs(finalHeight - self.targetHeight) > 4 {
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
    case noActiveStream

    var errorDescription: String? {
        switch self {
        case .persistenceNotConfigured:
            return "Database not configured"
        case .assetServiceNotConfigured:
            return "Asset storage not configured"
        case .noActiveStream:
            return "No active stream"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let quickPanelDidShow = Notification.Name("QuickPanelDidShow")
    static let quickPanelDidHide = Notification.Name("QuickPanelDidHide")
}
