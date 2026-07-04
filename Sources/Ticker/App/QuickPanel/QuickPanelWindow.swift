import AppKit

/// Custom NSPanel for the Quick Panel feature
/// Ephemeral floating panel that appears near cursor/selection
/// Auto-dismisses on ESC or blur (clicking outside)
final class QuickPanelWindow: NSPanel, NSWindowDelegate {

    // MARK: - Configuration

    static let defaultWidth: CGFloat = 350
    static let minHeight: CGFloat = 80
    static let maxHeight: CGFloat = 600

    /// Callback when panel should dismiss
    var onDismiss: (() -> Void)?
    /// Callback for Escape so all focus states use the same graduated handling.
    var onEscape: (() -> Void)?

    // MARK: - NSPanel Overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Initialization

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.minHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        setupVisualEffect()
        delegate = self
    }

    // MARK: - NSWindowDelegate (Blur Dismissal)

    func windowDidResignKey(_ notification: Notification) {
        // Auto-dismiss when user clicks outside the panel
        onDismiss?()
    }

    private func configurePanel() {
        // Panel behavior
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false  // We handle dismissal manually

        // Enable dragging by clicking anywhere on the panel background
        isMovableByWindowBackground = true

        // Set up content view with layer for clipping
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 10
        contentView?.layer?.masksToBounds = true
    }

    private func setupVisualEffect() {
        guard let contentView = contentView else { return }

        // Create visual effect view that fills the content view
        let visualEffect = NSVisualEffectView(frame: contentView.bounds)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        contentView.addSubview(visualEffect, positioned: .below, relativeTo: nil)
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        // ESC uses the same graduated Quick Panel semantics regardless of focus.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ESC via responder chain
        onEscape?()
    }

    // MARK: - Positioning

    /// Position the panel at a specific point (bottom-left origin)
    func position(at point: CGPoint) {
        setFrameOrigin(point)
    }

    /// Reset panel to initial minimum height
    func resetToMinHeight() {
        var newFrame = frame
        let heightDelta = Self.minHeight - frame.height
        newFrame.origin.y -= heightDelta
        newFrame.size.height = Self.minHeight
        setFrame(newFrame, display: true)
    }

    /// Resize panel height (animates)
    /// Keeps top edge fixed but ensures panel stays on screen
    func resize(toHeight height: CGFloat, animated: Bool = true, completion: (() -> Void)? = nil) {
        let newHeight = max(Self.minHeight, min(height, Self.maxHeight))

        // Calculate the target frame
        var newFrame = frame
        // Keep top edge fixed (adjust origin.y as height changes)
        let heightDelta = newHeight - frame.height
        newFrame.origin.y -= heightDelta
        newFrame.size.height = newHeight

        // Ensure panel stays on screen
        if let screen = self.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            let margin: CGFloat = 8

            // If bottom edge goes below screen, push the panel up
            if newFrame.origin.y < screenFrame.minY + margin {
                newFrame.origin.y = screenFrame.minY + margin
            }

            // If top edge goes above screen, push the panel down
            if newFrame.maxY > screenFrame.maxY - margin {
                newFrame.origin.y = screenFrame.maxY - margin - newFrame.height
            }

            // Keep horizontal bounds as well
            newFrame.origin.x = max(screenFrame.minX + margin,
                                    min(newFrame.origin.x, screenFrame.maxX - newFrame.width - margin))
        }

        // Skip if frame is essentially the same
        guard abs(frame.height - newFrame.height) > 1 ||
              abs(frame.origin.y - newFrame.origin.y) > 1 else {
            completion?()
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(newFrame, display: true)
            }, completionHandler: {
                completion?()
            })
        } else {
            setFrame(newFrame, display: true)
            completion?()
        }
    }
}
