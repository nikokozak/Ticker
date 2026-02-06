import AppKit
import ApplicationServices

/// Service for getting cursor and selection position using Accessibility APIs
/// Requires accessibility permission for focused element and selection bounds
/// Falls back gracefully when permission not available
final class CursorPositionService {

    // MARK: - Permission

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Position Detection

    /// Get the position of the currently focused UI element
    /// Returns nil if no permission or no focused element
    func getFocusedElementPosition() -> CGPoint? {
        guard hasAccessibilityPermission else { return nil }

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

        // Get position of the focused element
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        guard positionResult == .success, let posValue = positionValue else {
            return nil
        }

        var point = CGPoint.zero
        if AXValueGetValue(posValue as! AXValue, .cgPoint, &point) {
            return point
        }

        return nil
    }

    /// Get current mouse location (screen coordinates)
    /// Always works, no permission needed
    func getMouseLocation() -> CGPoint {
        NSEvent.mouseLocation
    }

    // MARK: - Position Calculation

    /// Calculate best position for a panel near the mouse cursor
    /// Returns position in Cocoa coordinates (bottom-left origin)
    func calculatePanelPosition(panelSize: CGSize) -> CGPoint {
        let mouseLocation = getMouseLocation()

        // Find screen containing the mouse cursor
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        guard let screen = screen else {
            return CGPoint(x: 100, y: 100)
        }

        let screenFrame = screen.visibleFrame  // Use visibleFrame to account for dock/menubar

        var x = mouseLocation.x - panelSize.width / 2  // Center horizontally on mouse
        var y = mouseLocation.y - panelSize.height - 20  // Below mouse

        // Ensure panel stays on this screen
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panelSize.width - 8))
        y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - panelSize.height - 8))

        return CGPoint(x: x, y: y)
    }
}
