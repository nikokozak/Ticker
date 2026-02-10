import AppKit

protocol TickerNextEditorTextViewActionHandling: AnyObject {
    func tickerNextEditorTextView(
        _ textView: TickerNextEditorTextView,
        didRequestAction action: TickerNextSelectionAIAction
    )
    func tickerNextEditorTextView(
        _ textView: TickerNextEditorTextView,
        didCommandClickAtUTF16Offset offset: Int
    ) -> Bool
}

final class TickerNextEditorTextView: NSTextView {
    private static let aiMenuTag = 31_001
    private static let aiSeparatorTag = 31_002

    weak var actionHandler: TickerNextEditorTextViewActionHandling?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let utf16Offset = utf16OffsetForEvent(event),
           actionHandler?.tickerNextEditorTextView(self, didCommandClickAtUTF16Offset: utf16Offset) == true {
            return
        }

        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "Context")
        removeTickerNextAIMenuItems(from: menu)

        let hasSelection = selectedRange().length > 0

        let aiMenuItem = NSMenuItem(title: "AI", action: nil, keyEquivalent: "")
        aiMenuItem.tag = Self.aiMenuTag
        let aiSubmenu = NSMenu(title: "AI")

        let rewrite = NSMenuItem(title: "Rewrite...", action: #selector(handleRewrite), keyEquivalent: "")
        rewrite.target = self
        rewrite.isEnabled = hasSelection
        aiSubmenu.addItem(rewrite)

        let proofread = NSMenuItem(title: "Proofread", action: #selector(handleProofread), keyEquivalent: "")
        proofread.target = self
        proofread.isEnabled = hasSelection
        aiSubmenu.addItem(proofread)

        let summarize = NSMenuItem(title: "Summarize", action: #selector(handleSummarize), keyEquivalent: "")
        summarize.target = self
        summarize.isEnabled = hasSelection
        aiSubmenu.addItem(summarize)

        aiMenuItem.submenu = aiSubmenu

        if !menu.items.isEmpty {
            let separator = NSMenuItem.separator()
            separator.tag = Self.aiSeparatorTag
            menu.addItem(separator)
        }
        menu.addItem(aiMenuItem)

        return menu
    }

    @objc private func handleRewrite() {
        actionHandler?.tickerNextEditorTextView(self, didRequestAction: .rewrite)
    }

    @objc private func handleProofread() {
        actionHandler?.tickerNextEditorTextView(self, didRequestAction: .proofread)
    }

    @objc private func handleSummarize() {
        actionHandler?.tickerNextEditorTextView(self, didRequestAction: .summarize)
    }

    private func removeTickerNextAIMenuItems(from menu: NSMenu) {
        for index in stride(from: menu.items.count - 1, through: 0, by: -1) {
            let item = menu.items[index]
            if item.tag == Self.aiMenuTag || item.tag == Self.aiSeparatorTag {
                menu.removeItem(at: index)
            }
        }
    }

    private func utf16OffsetForEvent(_ event: NSEvent) -> Int? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        let pointInContainer = NSPoint(
            x: pointInView.x - textContainerOrigin.x,
            y: pointInView.y - textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let usedRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard usedRect.contains(pointInContainer) else {
            return nil
        }

        let glyphIndex = layoutManager.glyphIndex(for: pointInContainer, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return min(max(0, charIndex), (string as NSString).length)
    }
}
