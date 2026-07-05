import AppKit
import ApplicationServices

enum SelectionCaptureOutcome: Equatable {
    case notAttempted
    case internalApp
    case noPermission
    case ax
    case axHinted
    case clipboard
    case emptyExternal

    var telemetryRung: String {
        switch self {
        case .ax:
            return "ax"
        case .axHinted:
            return "ax-hinted"
        case .clipboard:
            return "clipboard"
        case .notAttempted, .internalApp, .noPermission, .emptyExternal:
            return "none"
        }
    }
}

struct SelectionCaptureResult: Equatable {
    let text: String?
    let outcome: SelectionCaptureOutcome
}

struct PasteboardSnapshot: Equatable {
    struct Item: Equatable {
        struct Entry: Equatable {
            let type: NSPasteboard.PasteboardType
            let data: Data
        }

        let entries: [Entry]
    }

    let changeCount: Int
    let items: [Item]

    init(pasteboard: NSPasteboard = .general) {
        self.changeCount = pasteboard.changeCount
        self.items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(entries: item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return Item.Entry(type: type, data: data)
            })
        }
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()

        let restoredItems: [NSPasteboardItem] = items.compactMap { snapshotItem in
            let pasteboardItem = NSPasteboardItem()
            var restoredAnyType = false

            for entry in snapshotItem.entries {
                if pasteboardItem.setData(entry.data, forType: entry.type) {
                    restoredAnyType = true
                }
            }

            return restoredAnyType ? pasteboardItem : nil
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

/// Service for reading selected text and active application information
/// Uses Accessibility APIs when available, with graceful fallbacks
final class SelectionReaderService {

    private let cursorService: CursorPositionService
    private let maxSelectionReadAttempts = 2
    private let selectionReadRetryDelay: TimeInterval = 0.02
    private let hintedSelectionReadAttempts = 6
    private let hintedSelectionReadRetryDelay: TimeInterval = 0.05
    private let clipboardPollAttempts = 15
    private let clipboardPollDelay: TimeInterval = 0.02
    private var hintedApplicationPIDs = Set<pid_t>()

    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let copyKeyCode = CGKeyCode(8)

    init(cursorService: CursorPositionService? = nil) {
        self.cursorService = cursorService ?? CursorPositionService()
    }

    static func isCurrentAppBundle(activeBundleId: String?, currentBundleId: String?) -> Bool {
        guard let activeBundleId, let currentBundleId else {
            return false
        }
        return activeBundleId == currentBundleId
    }

    static func resolveSelectedText(
        activeBundleId: String?,
        currentBundleId: String?,
        localSelection: @MainActor () async -> String?,
        axSelection: () -> String?
    ) async -> String? {
        if isCurrentAppBundle(activeBundleId: activeBundleId, currentBundleId: currentBundleId) {
            return await localSelection()
        }

        return axSelection()
    }

    static func resolveSelectedTextWithOutcome(
        activeBundleId: String?,
        currentBundleId: String?,
        localSelection: @MainActor () async -> String?,
        externalSelection: () -> SelectionCaptureResult
    ) async -> SelectionCaptureResult {
        if isCurrentAppBundle(activeBundleId: activeBundleId, currentBundleId: currentBundleId) {
            return SelectionCaptureResult(
                text: await localSelection(),
                outcome: .internalApp
            )
        }

        return externalSelection()
    }

    static func captureExternalSelectedText(
        hasAccessibilityPermission: Bool,
        axSelection: () -> String?,
        hintAccessibilityTree: () -> Void,
        hintedAXSelection: () -> String?,
        clipboardSelection: () -> String?
    ) -> SelectionCaptureResult {
        guard hasAccessibilityPermission else {
            return SelectionCaptureResult(text: nil, outcome: .noPermission)
        }

        if let text = nonEmptyText(axSelection()) {
            return SelectionCaptureResult(text: text, outcome: .ax)
        }

        hintAccessibilityTree()

        if let text = nonEmptyText(hintedAXSelection()) {
            return SelectionCaptureResult(text: text, outcome: .axHinted)
        }

        if let text = nonEmptyText(clipboardSelection()) {
            return SelectionCaptureResult(text: text, outcome: .clipboard)
        }

        return SelectionCaptureResult(text: nil, outcome: .emptyExternal)
    }

    // MARK: - Selection Reading

    /// Get currently selected text from the focused application
    /// Returns nil if no permission, no selection, or app doesn't support it
    func getSelectedText() -> String? {
        guard cursorService.hasAccessibilityPermission else {
            return nil
        }

        for attempt in 1...maxSelectionReadAttempts {
            guard let focusedElement = getFocusedElement() else {
                return nil
            }

            let selectionResult = extractSelectedText(from: focusedElement)
            if let text = selectionResult.text {
                return text
            }

            if attempt == maxSelectionReadAttempts || !shouldRetrySelectionRead(for: selectionResult.error) {
                break
            }

            Thread.sleep(forTimeInterval: selectionReadRetryDelay)
        }

        return nil
    }

    func captureSelectedText() -> SelectionCaptureResult {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleId = frontmostApp?.bundleIdentifier
        var useHintSettleBudget = false

        let result = Self.captureExternalSelectedText(
            hasAccessibilityPermission: cursorService.hasAccessibilityPermission,
            axSelection: { [self] in
                getSelectedText()
            },
            hintAccessibilityTree: { [self] in
                useHintSettleBudget = hintAccessibilityTree(for: frontmostApp)
            },
            hintedAXSelection: { [self] in
                readSelectedTextFromFocusedElement(
                    attempts: useHintSettleBudget ? hintedSelectionReadAttempts : 1,
                    retryDelay: useHintSettleBudget ? hintedSelectionReadRetryDelay : 0,
                    retryMissingFocusedElement: useHintSettleBudget,
                    retryEmptySelection: useHintSettleBudget
                )
            },
            clipboardSelection: { [self] in
                copySelectedTextThroughClipboard(from: frontmostApp)
            }
        )

        DebugLog.log(
            "[SelectionReader] external capture " +
            "rung=\(result.outcome.telemetryRung) " +
            "selectedLength=\(result.text?.count ?? 0) " +
            "activeBundleId=\(frontmostBundleId ?? "unknown")"
        )

        return result
    }

    private func readSelectedTextFromFocusedElement(
        attempts: Int,
        retryDelay: TimeInterval,
        retryMissingFocusedElement: Bool,
        retryEmptySelection: Bool
    ) -> String? {
        let cappedAttempts = max(1, attempts)

        for attempt in 1...cappedAttempts {
            guard let focusedElement = getFocusedElement() else {
                if retryMissingFocusedElement && attempt < cappedAttempts {
                    Thread.sleep(forTimeInterval: retryDelay)
                    continue
                }
                return nil
            }

            let selectionResult = extractSelectedText(from: focusedElement)
            if let text = selectionResult.text {
                return text
            }

            let shouldRetry = retryEmptySelection || shouldRetrySelectionRead(for: selectionResult.error)
            if attempt == cappedAttempts || !shouldRetry {
                break
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        return nil
    }

    private func getFocusedElement() -> AXUIElement? {
        if let element = focusedElement(of: AXUIElementCreateSystemWide()) {
            return element
        }

        // Sequoia regression (old repo #121): the system-wide focus query fails
        // outright for some apps (kitty: kAXErrorCannotComplete) while the app's
        // own AX element still answers. Fall back to the frontmost app.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return focusedElement(of: AXUIElementCreateApplication(pid))
    }

    private func focusedElement(of container: AXUIElement) -> AXUIElement? {
        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            container,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard focusedElementResult == .success, let focusedElementValue else {
            return nil
        }

        guard CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedElementValue, to: AXUIElement.self)
    }

    private func extractSelectedText(from element: AXUIElement) -> (text: String?, error: AXError?) {
        // Primary path: direct selected text attribute.
        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if let selectedText = normalizeAxTextValue(selectedTextValue) {
            return (selectedText, nil)
        }

        // Fallback for apps that expose only selected range + string-for-range.
        if let selectedTextForRange = selectedTextFromRange(element: element) {
            return (selectedTextForRange, nil)
        }

        if selectedTextResult == .success {
            return (nil, nil)
        }

        return (nil, selectedTextResult)
    }

    private func selectedTextFromRange(element: AXUIElement) -> String? {
        var selectedRangeValue: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )

        guard selectedRangeResult == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let selectedRangeAxValue = unsafeBitCast(selectedRangeValue, to: AXValue.self)

        var selectedRange = CFRange()
        guard AXValueGetType(selectedRangeAxValue) == .cfRange,
              AXValueGetValue(selectedRangeAxValue, .cfRange, &selectedRange),
              selectedRange.length > 0 else {
            return nil
        }

        if let textForRange = textForRangeAttribute(
            element: element,
            attribute: kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue: selectedRangeAxValue
        ) {
            return textForRange
        }

        if let attributedTextForRange = textForRangeAttribute(
            element: element,
            attribute: kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue: selectedRangeAxValue
        ) {
            return attributedTextForRange
        }

        return nil
    }

    private func textForRangeAttribute(
        element: AXUIElement,
        attribute: CFString,
        rangeValue: AXValue
    ) -> String? {
        var rangeTextValue: CFTypeRef?
        let rangeTextResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            rangeValue,
            &rangeTextValue
        )

        guard rangeTextResult == .success else {
            return nil
        }

        return normalizeAxTextValue(rangeTextValue)
    }

    private func normalizeAxTextValue(_ value: CFTypeRef?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }

        if let attributedText = value as? NSAttributedString, !attributedText.string.isEmpty {
            return attributedText.string
        }

        return nil
    }

    private func shouldRetrySelectionRead(for error: AXError?) -> Bool {
        guard let error else {
            return false
        }

        switch error {
        case .cannotComplete, .failure:
            return true
        default:
            return false
        }
    }

    private func hintAccessibilityTree(for app: NSRunningApplication?) -> Bool {
        guard let app else {
            return false
        }

        let pid = app.processIdentifier
        let wasAlreadyHinted = hintedApplicationPIDs.contains(pid)
        guard !wasAlreadyHinted else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            appElement,
            Self.axEnhancedUserInterfaceAttribute,
            kCFBooleanTrue
        )
        AXUIElementSetAttributeValue(
            appElement,
            Self.axManualAccessibilityAttribute,
            kCFBooleanTrue
        )
        hintedApplicationPIDs.insert(pid)

        return true
    }

    private func copySelectedTextThroughClipboard(from app: NSRunningApplication?) -> String? {
        guard let app else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        // Post ⌘C to the system HID stream, not the app's pid: GLFW/game-loop apps
        // (kitty, Alacritty) never see pid-targeted events. Capture runs before the
        // panel shows, so the target app is still the focused one.
        postCopyShortcut()

        guard waitForPasteboardChange(pasteboard, after: snapshot.changeCount) else {
            return nil
        }

        let copiedText = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)

        return copiedText
    }

    private func postCopyShortcut() {
        // GLFW apps (kitty, Alacritty) track modifiers from the modifier key's own
        // events, not from flags on the letter key — synthesize the full ⌘C sequence.
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode = CGKeyCode(55)  // kVK_Command

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true)
        commandDown?.flags = .maskCommand
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.copyKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.copyKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        commandUp?.flags = []

        for event in [commandDown, keyDown, keyUp, commandUp] {
            event?.post(tap: .cghidEventTap)
            usleep(5_000)
        }
    }

    private func waitForPasteboardChange(_ pasteboard: NSPasteboard, after changeCount: Int) -> Bool {
        for attempt in 1...clipboardPollAttempts {
            if pasteboard.changeCount != changeCount {
                return true
            }

            if attempt < clipboardPollAttempts {
                Thread.sleep(forTimeInterval: clipboardPollDelay)
            }
        }

        return pasteboard.changeCount != changeCount
    }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Active App Information

    /// Get the name of the currently active/frontmost application
    func getActiveApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Get the bundle identifier of the currently active application
    func getActiveAppBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Get the title of the frontmost window
    /// Requires accessibility permission
    func getActiveWindowTitle() -> String? {
        guard cursorService.hasAccessibilityPermission else {
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get focused window
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard windowResult == .success,
              let focusedWindow,
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = unsafeBitCast(focusedWindow, to: AXUIElement.self)

        // Get window title
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        if titleResult == .success, let title = titleValue as? String {
            return title
        }

        return nil
    }

    // MARK: - Context Building

    /// Build a context from available selection, app info, and position
    /// Captures everything at once BEFORE focus changes
    func buildContext(
        selectedText providedSelectedText: String? = nil,
        selectionCaptureOutcome: SelectionCaptureOutcome = .notAttempted,
        readSelectionFromAX: Bool = true,
        panelSize: CGSize = CGSize(width: QuickPanelWindow.defaultWidth, height: QuickPanelWindow.minHeight)
    ) -> QuickPanelContext {
        let axTrusted = cursorService.hasAccessibilityPermission
        DebugLog.log("[SelectionReader] buildContext axTrusted=\(axTrusted)")

        // Capture position first (uses selection bounds if available, else mouse)
        let position = cursorService.calculatePanelPosition(panelSize: panelSize)

        let selectedText = providedSelectedText ?? (readSelectionFromAX ? getSelectedText() : nil)

        // Only grab clipboard image if no text selection
        var clipboardImageData: Data? = nil
        if selectedText == nil || selectedText?.isEmpty == true {
            clipboardImageData = getRecentClipboardImage()
        }

        let context = QuickPanelContext(
            selectedText: selectedText,
            activeApp: getActiveApp(),
            windowTitle: getActiveWindowTitle(),
            panelPosition: position,
            clipboardImage: clipboardImageData,
            isScreenshot: false,
            selectionCaptureOutcome: selectionCaptureOutcome
        )
        DebugLog.log(
            "[SelectionReader] buildContext result " +
            "hasSelection=\(context.hasSelection) " +
            "selectedLength=\(context.trimmedSelectedText?.count ?? 0) " +
            "hasImage=\(context.hasImage) " +
            "activeApp=\(context.activeApp ?? "unknown")"
        )
        return context
    }

    /// Get clipboard image if it was copied recently (within threshold)
    /// Returns PNG data for the image
    /// Note: PNG conversion runs synchronously. ClipboardService limits to 5MB to avoid
    /// significant frame drops. For 4K screenshots this is typically <100ms which is
    /// acceptable since the user just triggered the panel.
    private func getRecentClipboardImage() -> Data? {
        // Only grab image if clipboard was modified recently (60 seconds)
        guard ClipboardService.wasRecentlyModified(threshold: 60) else {
            return nil
        }

        return ClipboardService.getImageData()
    }
}

/// Context captured when Quick Panel is invoked
struct QuickPanelContext {
    let selectedText: String?
    let activeApp: String?
    let windowTitle: String?
    /// Panel position captured at the same time as context (before focus changes)
    let panelPosition: CGPoint
    /// Clipboard image data (if no text selection and clipboard has image)
    let clipboardImage: Data?
    /// True only for explicit app-initiated screenshot mode (currently deprecated).
    /// Clipboard-derived images should keep this false.
    let isScreenshot: Bool
    /// Outcome of the external-app selection ladder when Quick Panel was invoked.
    let selectionCaptureOutcome: SelectionCaptureOutcome

    init(
        selectedText: String?,
        activeApp: String?,
        windowTitle: String?,
        panelPosition: CGPoint,
        clipboardImage: Data?,
        isScreenshot: Bool,
        selectionCaptureOutcome: SelectionCaptureOutcome = .notAttempted
    ) {
        self.selectedText = selectedText
        self.activeApp = activeApp
        self.windowTitle = windowTitle
        self.panelPosition = panelPosition
        self.clipboardImage = clipboardImage
        self.isScreenshot = isScreenshot
        self.selectionCaptureOutcome = selectionCaptureOutcome
    }

    var trimmedSelectedText: String? {
        guard let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var hasSelection: Bool {
        trimmedSelectedText != nil
    }

    var hasImage: Bool {
        clipboardImage != nil
    }

    var hasContent: Bool {
        hasSelection || hasImage
    }

    /// Truncated preview of selected text for display
    var selectionPreview: String? {
        guard let text = trimmedSelectedText else { return nil }
        if text.count <= 100 {
            return text
        }
        return String(text.prefix(97)) + "..."
    }
}
