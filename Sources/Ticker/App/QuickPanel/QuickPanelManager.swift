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
        let capturedContext = selectionService.buildContext()

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
        show(with: capturedContext)
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
                clipboardImage: imageData
            )
            statusMessage = "Screenshot attached"
            // Auto-clear status after 2 seconds
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.statusMessage == "Screenshot attached" {
                    self.statusMessage = nil
                }
            }
        }

        show(with: capturedContext)
    }

    /// Show the quick panel with specific context
    private func show(with capturedContext: QuickPanelContext) {
        self.context = capturedContext
        resetState()

        // Load available streams for picker
        loadAvailableStreams()

        // Show accessibility warning if permission not granted and no context captured
        if !cursorService.hasAccessibilityPermission {
            if !capturedContext.hasContent {
                statusMessage = "Grant Accessibility permission to capture text selections"
            }
            cursorService.requestAccessibilityPermission()
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
        await addToStream(triggerAI: false)
    }

    /// Handle Cmd+Enter - add content and trigger AI
    func handleCmdEnter() async {
        await addToStream(triggerAI: true)
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
            inputText = ""
            context = nil
            return
        }

        // Third: hide panel
        hide()
    }

    /// Clear attached context
    func clearContext() {
        context = nil
    }

    // MARK: - Cell Creation

    /// Add captured content and/or input to the active stream
    private func addToStream(triggerAI: Bool) async {
        guard let persistence = persistence else {
            error = "Persistence not configured"
            return
        }

        let hasContext = context?.hasContent == true
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

            // Get insertion order - inserts before trailing empty cell if one exists
            // This bumps the empty cell's order, so we only call it once
            var nextOrder = try persistence.getInsertionOrderForQuickPanel(streamId: streamId)

            var cellsToAdd: [Cell] = []
            var contextCellId: UUID?

            // 1. If we have context (selection or image), create a quote cell
            if let ctx = context, ctx.hasContent {
                let contextCell = createContextCell(from: ctx, streamId: streamId, order: nextOrder)
                cellsToAdd.append(contextCell)
                contextCellId = contextCell.id
                try persistence.saveCell(contextCell)
                nextOrder += 1
            }

            // 2. If we have input text
            if hasInput {
                let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

                if triggerAI {
                    // Create AI response cell that references context
                    let aiCell = Cell(
                        streamId: streamId,
                        content: "",  // Will be filled by AI
                        originalPrompt: trimmedInput,
                        type: .aiResponse,
                        order: nextOrder,
                        references: contextCellId.map { [$0] }
                    )
                    cellsToAdd.append(aiCell)
                    try persistence.saveCell(aiCell)

                    // Notify frontend to trigger AI on this cell
                    notifyFrontend(streamId: streamId, cells: cellsToAdd, triggerAI: aiCell.id, isNewStream: isNewStream)
                } else {
                    // Create plain text cell
                    let textCell = Cell(
                        streamId: streamId,
                        content: "<p>\(escapeHtml(trimmedInput))</p>",
                        type: .text,
                        order: nextOrder
                    )
                    cellsToAdd.append(textCell)
                    try persistence.saveCell(textCell)

                    notifyFrontend(streamId: streamId, cells: cellsToAdd, triggerAI: nil, isNewStream: isNewStream)
                }
            } else {
                // Context only - just notify
                notifyFrontend(streamId: streamId, cells: cellsToAdd, triggerAI: nil, isNewStream: isNewStream)
            }

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

    /// Create a quote cell from captured context
    private func createContextCell(from ctx: QuickPanelContext, streamId: UUID, order: Int) -> Cell {
        var content = ""

        // Build source attribution: "App — Window Title" or just "App"
        let sourceAttribution = buildSourceAttribution(app: ctx.activeApp, windowTitle: ctx.windowTitle)

        if let text = ctx.selectedText {
            // Format as italicized quote with source info
            let escapedText = escapeHtml(text)
            content = "<p><em>\(escapedText)</em></p>"

            if let source = sourceAttribution {
                content += "<p class=\"source-info\">— \(source)</p>"
            }
        } else if let imageData = ctx.clipboardImage, let assetService = assetService {
            // Save image via AssetService and embed as img tag
            do {
                let relativePath = try assetService.saveImage(data: imageData, streamId: streamId)
                // Use relative path for portability - AssetSchemeHandler resolves at render time
                // Note: ticker-asset:/// (three slashes) ensures the path isn't parsed as host
                let assetUrl = "ticker-asset:///\(relativePath)"
                content = "<p><img src=\"\(assetUrl)\" alt=\"Screenshot\" style=\"max-width: 100%;\"></p>"

                if let source = sourceAttribution {
                    content += "<p class=\"source-info\">— Screenshot from \(source)</p>"
                }
            } catch {
                DebugLog.log("[QuickPanel] Failed to save screenshot (\(DebugLog.errorSummary(error)))")
                content = "<p>[Screenshot failed to save]</p>"
            }
        }

        return Cell(
            streamId: streamId,
            content: content,
            type: .quote,
            order: order,
            sourceApp: ctx.activeApp
        )
    }

    /// Build source attribution string from app name and window title
    private func buildSourceAttribution(app: String?, windowTitle: String?) -> String? {
        let escapedApp = app.map { escapeHtml($0) }
        let escapedTitle = windowTitle.map { escapeHtml($0) }

        switch (escapedApp, escapedTitle) {
        case let (app?, title?) where !title.isEmpty:
            // Truncate long titles
            let truncatedTitle = title.count > 60 ? String(title.prefix(57)) + "..." : title
            return "\(app) — \(truncatedTitle)"
        case let (app?, _):
            return app
        case let (nil, title?) where !title.isEmpty:
            return title
        default:
            return nil
        }
    }

    /// Notify the React frontend about new cells
    /// When isNewStream is true, includes stream metadata so frontend can add it without creating a blank cell
    private func notifyFrontend(streamId: UUID, cells: [Cell], triggerAI: UUID?, isNewStream: Bool = false) {
        guard let bridgeService = bridgeService else { return }

        var payload: [String: AnyCodable] = [
            "streamId": AnyCodable(streamId.uuidString),
            "cells": AnyCodable(cells.map { cellToDict($0) }),
            "isNewStream": AnyCodable(isNewStream)
        ]

        if let aiCellId = triggerAI {
            payload["triggerAI"] = AnyCodable(aiCellId.uuidString)
        }

        bridgeService.send(BridgeMessage(type: "quickPanelCellsAdded", payload: payload))
    }

    /// Convert Cell to dictionary for bridge
    private func cellToDict(_ cell: Cell) -> [String: Any] {
        var dict: [String: Any] = [
            "id": cell.id.uuidString,
            "streamId": cell.streamId.uuidString,
            "content": cell.content,
            "type": cell.type.rawValue,
            "order": cell.order,
            "createdAt": ISO8601DateFormatter().string(from: cell.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: cell.updatedAt)
        ]
        if let sourceApp = cell.sourceApp {
            dict["sourceApp"] = sourceApp
        }
        if let originalPrompt = cell.originalPrompt {
            dict["originalPrompt"] = originalPrompt
        }
        if let references = cell.references {
            dict["references"] = references.map { $0.uuidString }
        }
        return dict
    }

    /// Simple HTML escaping
    private func escapeHtml(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
    case noActiveStream

    var errorDescription: String? {
        switch self {
        case .persistenceNotConfigured:
            return "Database not configured"
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
