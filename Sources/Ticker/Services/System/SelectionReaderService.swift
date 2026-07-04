import AppKit
import ApplicationServices

/// Service for reading selected text and active application information
/// Uses Accessibility APIs when available, with graceful fallbacks
final class SelectionReaderService {

    private let cursorService: CursorPositionService
    private let maxSelectionReadAttempts = 2
    private let selectionReadRetryDelay: TimeInterval = 0.02

    init(cursorService: CursorPositionService? = nil) {
        self.cursorService = cursorService ?? CursorPositionService()
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

    private func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemWide,
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
    func buildContext() -> QuickPanelContext {
        let axTrusted = cursorService.hasAccessibilityPermission
        DebugLog.log("[SelectionReader] buildContext axTrusted=\(axTrusted)")

        // Capture position first (uses selection bounds if available, else mouse)
        let panelSize = CGSize(width: 350, height: 80)  // Default panel size
        let position = cursorService.calculatePanelPosition(panelSize: panelSize)

        let selectedText = getSelectedText()

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
            isScreenshot: false
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
