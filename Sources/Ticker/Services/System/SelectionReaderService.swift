import AppKit
import ApplicationServices

/// Service for reading selected text and active application information
/// Uses Accessibility APIs when available, with graceful fallbacks
final class SelectionReaderService {

    private let cursorService: CursorPositionService

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

        // Get system-wide accessibility element
        let systemWide = AXUIElementCreateSystemWide()

        // Get focused application
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        // Get focused element from the application
        var focusedElement: CFTypeRef?
        let elementResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard elementResult == .success, let element = focusedElement else {
            return nil
        }

        // Try to get selected text directly
        var selectedText: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        if textResult == .success, let text = selectedText as? String, !text.isEmpty {
            return text
        }

        return nil
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

        guard windowResult == .success, let window = focusedWindow else {
            return nil
        }

        // Get window title
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
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
        // Capture position first (uses selection bounds if available, else mouse)
        let panelSize = CGSize(width: 350, height: 80)  // Default panel size
        let position = cursorService.calculatePanelPosition(panelSize: panelSize)

        let selectedText = getSelectedText()

        // Only grab clipboard image if no text selection
        var clipboardImageData: Data? = nil
        if selectedText == nil || selectedText?.isEmpty == true {
            clipboardImageData = getRecentClipboardImage()
        }

        return QuickPanelContext(
            selectedText: selectedText,
            activeApp: getActiveApp(),
            windowTitle: getActiveWindowTitle(),
            panelPosition: position,
            clipboardImage: clipboardImageData,
            isScreenshot: false
        )
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
    /// True only when the image was captured via Ticker's screenshot hotkey (Cmd+;).
    /// Used for UI styling (avoid transient "toast" messages).
    let isScreenshot: Bool

    var hasSelection: Bool {
        selectedText != nil && !(selectedText?.isEmpty ?? true)
    }

    var hasImage: Bool {
        clipboardImage != nil
    }

    var hasContent: Bool {
        hasSelection || hasImage
    }

    /// Truncated preview of selected text for display
    var selectionPreview: String? {
        guard let text = selectedText else { return nil }
        if text.count <= 100 {
            return text
        }
        return String(text.prefix(97)) + "..."
    }
}
