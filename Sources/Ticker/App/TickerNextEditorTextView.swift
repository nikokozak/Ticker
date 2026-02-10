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
        let hasSelection = selectedRange().length > 0
        let menu = NSMenu(title: "Context")

        let send = NSMenuItem(title: "Send", action: #selector(handleSend), keyEquivalent: "")
        send.target = self
        send.isEnabled = hasSelection
        menu.addItem(send)

        let sendWithPrompt = NSMenuItem(title: "Send with Prompt...", action: #selector(handleSendWithPrompt), keyEquivalent: "")
        sendWithPrompt.target = self
        sendWithPrompt.isEnabled = hasSelection
        menu.addItem(sendWithPrompt)

        menu.addItem(NSMenuItem.separator())

        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        cut.target = nil
        cut.isEnabled = hasSelection && isEditable
        menu.addItem(cut)

        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = nil
        copy.isEnabled = hasSelection
        menu.addItem(copy)

        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = nil
        paste.isEnabled = isEditable
        menu.addItem(paste)

        menu.addItem(NSMenuItem.separator())

        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        selectAll.target = nil
        menu.addItem(selectAll)

        return menu
    }

    @objc private func handleSend() {
        actionHandler?.tickerNextEditorTextView(self, didRequestAction: .send)
    }

    @objc private func handleSendWithPrompt() {
        actionHandler?.tickerNextEditorTextView(self, didRequestAction: .sendWithPrompt)
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
