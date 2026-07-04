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
    @Published var statusMessage: String?  // Temporary feedback (success/info messages)
    @Published var ephemeralConversation = EphemeralConversation()

    // Stream selection
    @Published private(set) var availableStreams: [StreamSummary] = []
    @Published var selectedStreamId: UUID?

    // MARK: - Services

    private let cursorService: CursorPositionService
    private let selectionService: SelectionReaderService
    private weak var persistence: PersistenceService?
    private weak var bridgeService: BridgeService?
    private var assetService: AssetService?
    private weak var orchestrator: AIOrchestrator?

    // MARK: - Streaming Task

    private var streamingTask: Task<Void, Never>?
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

    // MARK: - Public API

    /// Toggle the quick panel
    func toggle() {
        // Capture context BEFORE we steal focus
        let capturedContext = contextRespectingDismissedClipboardImage(selectionService.buildContext())

        if isVisible {
            // Check if there's a new selection
            let hasNewSelection = capturedContext.hasSelection &&
                capturedContext.selectedText != context?.selectedText

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
                isScreenshot: true
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
            isScreenshot: false
        )

        show(with: contextWithoutClipboard, showAccessibilityWarning: false)
        statusMessage = message

        // Auto-clear after a short delay so it doesn't linger.
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4s
            if self.statusMessage == message {
                self.statusMessage = nil
            }
        }
    }

    /// Show the quick panel with specific context
    private func show(with capturedContext: QuickPanelContext, showAccessibilityWarning: Bool) {
        self.context = capturedContext
        resetState()

        // Load available streams for picker
        loadAvailableStreams()

        // If Accessibility isn't granted, just show a soft warning (don't prompt).
        // Onboarding is responsible for prompting; repeated system prompts here are jarring.
        if showAccessibilityWarning && !cursorService.hasAccessibilityPermission && !capturedContext.hasContent {
            statusMessage = "Grant Accessibility permission to capture text selections"
        }

        // Create panel if needed
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        // Position at captured location
        panel.position(at: capturedContext.panelPosition)

        // Show panel without bringing main window forward
        panel.orderFrontRegardless()
        panel.makeKey()

        isVisible = true

        // Post notification for input focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .quickPanelDidShow, object: nil)
        }
    }

    /// Hide the quick panel
    func hide() {
        // Cancel any in-flight streaming to avoid orphan AI calls
        cancelStreaming()

        panel?.orderOut(nil)
        isVisible = false
        resetState()
        statusMessage = nil
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
        // TODO(task-1.4): Restore Quick Panel AI handling on the document model.
        await addToStream()
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
        let contextForAI: String? = isFirstTurn ? context?.selectedText : nil

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
                streamId: nil,  // Ephemeral - not tied to real stream
                priorCells: priorCells,
                sourceContext: contextForAI,
                systemPromptOverride: Prompts.quickPanelChat,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self = self, !self.isStreamingCancelled else { return }
                        self.ephemeralConversation.currentResponse += chunk
                    }
                },
                onComplete: { [weak self] in
                    Task { @MainActor in
                        guard let self = self, !self.isStreamingCancelled else { return }
                        // Record assistant turn with completed response
                        self.ephemeralConversation.turns.append(ConversationTurn(
                            role: .assistant,
                            content: self.ephemeralConversation.currentResponse,
                            contextIncluded: false
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

        // Second: clear input/context
        if !inputText.isEmpty || context?.hasContent == true {
            suppressDismissedClipboardImageIfNeeded()
            inputText = ""
            context = nil
            return
        }

        // Third: hide panel
        hide()
    }

    /// Clear attached context
    func clearContext() {
        suppressDismissedClipboardImageIfNeeded()
        context = nil
    }

    /// Suppress reattaching the current clipboard image on Cmd+L until clipboard changes.
    private func suppressDismissedClipboardImageIfNeeded() {
        guard context?.hasImage == true else { return }
        suppressedClipboardImageChangeCount = ClipboardService.changeCount()
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
            isScreenshot: false
        )
    }

    // MARK: - Markdown Capture

    /// Add captured content and/or input to the active stream
    private func addToStream() async {
        guard let persistence = persistence else {
            error = "Persistence not configured"
            return
        }

        let hasContext = nonEmptyTrimmed(context?.selectedText) != nil || context?.clipboardImage != nil
        let hasInput = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
            let result = try persistence.appendToStreamDocument(streamId: streamId, fragment: fragment)
            notifyFrontend(streamId: streamId, fragment: result.fragment, isNewStream: isNewStream)

            // Success - hide panel
            hide()

        } catch {
            self.error = error.localizedDescription
            DebugLog.log("[QuickPanel] Error adding to stream (\(DebugLog.errorSummary(error)))")
        }

        isLoading = false
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
        var blocks: [String] = []

        if let ctx = context {
            if let selectedText = nonEmptyTrimmed(ctx.selectedText) {
                blocks.append(markdownBlockquote(selectedText))

                if let sourceApp = nonEmptyTrimmed(ctx.activeApp) {
                    blocks.append("*— \(escapeMarkdownEmphasis(sourceApp))*")
                }
            }

            if let imageData = ctx.clipboardImage {
                guard let assetService = assetService else {
                    throw QuickPanelError.assetServiceNotConfigured
                }

                let relativePath = try assetService.saveImage(data: imageData, streamId: streamId)
                blocks.append("![capture](ticker-asset:///\(relativePath))")
            }
        }

        if let input = nonEmptyTrimmed(inputText) {
            blocks.append(input)
        }

        return blocks.joined(separator: "\n\n")
    }

    private func markdownBlockquote(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.newlines)
            .map { line in
                line.isEmpty ? ">" : "> \(line)"
            }
            .joined(separator: "\n")
    }

    private func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func escapeMarkdownEmphasis(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Notify the React frontend about document appends.
    private func notifyFrontend(streamId: UUID, fragment: String, isNewStream: Bool = false) {
        guard let bridgeService = bridgeService else { return }

        let payload: [String: AnyCodable] = [
            "streamId": AnyCodable(streamId.uuidString),
            "fragment": AnyCodable(fragment),
            "isNewStream": AnyCodable(isNewStream),
            "source": AnyCodable("quickPanel")
        ]

        bridgeService.send(BridgeMessage(type: "streamDocumentAppended", payload: payload))
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let newPanel = QuickPanelWindow()

        newPanel.onDismiss = { [weak self] in
            self?.hide()
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

    /// Called by SwiftUI when content height changes
    func contentHeightChanged(_ height: CGFloat) {
        let clampedHeight = max(QuickPanelWindow.minHeight, min(height, QuickPanelWindow.maxHeight))

        // Skip if height hasn't meaningfully changed (reduces timer churn during streaming)
        guard abs(targetHeight - clampedHeight) > 2 else { return }
        targetHeight = clampedHeight

        heightDebounceTimer?.invalidate()
        // Longer debounce (150ms) to batch rapid content changes during streaming
        heightDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.applyHeightUpdate()
            }
        }
    }

    private func applyHeightUpdate() {
        guard let panel = panel else { return }

        // Skip if already animating - the completion handler will check if another update is needed
        guard !isAnimatingHeight else { return }

        let currentHeight = panel.frame.height
        // Require meaningful difference to animate (avoid micro-adjustments)
        guard abs(currentHeight - targetHeight) > 4 else { return }

        isAnimatingHeight = true
        panel.resize(toHeight: targetHeight, animated: true) { [weak self] in
            guard let self = self else { return }
            self.isAnimatingHeight = false

            // Check if height changed during animation - if so, schedule another update
            let finalHeight = self.panel?.frame.height ?? 0
            if abs(finalHeight - self.targetHeight) > 4 {
                self.applyHeightUpdate()
            }
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
