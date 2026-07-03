import AppKit
import PDFKit

struct PDFHighlightLinkPayload {
    let streamId: UUID
    let sourceId: UUID
    let sourceName: String
    let highlightId: String
    let page: Int
    let quote: String
}

private enum PDFReaderPanePresentationError: LocalizedError {
    case couldNotOpenPDFSource
    case notEnoughHorizontalSpace

    var errorDescription: String? {
        switch self {
        case .couldNotOpenPDFSource:
            return "Could not open PDF source."
        case .notEnoughHorizontalSpace:
            return "Not enough horizontal space to open the PDF pane."
        }
    }
}

private final class PDFPaneResizeHandleView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

final class PDFReaderPaneController: NSViewController {
    var onLinkSelection: ((PDFHighlightLinkPayload) -> Void)?
    var onClose: (() -> Void)?

    private let pdfPaneView = NSView(frame: .zero)
    private let pdfPaneHeaderView = NSView(frame: .zero)
    private let pdfPaneResizeHandle = PDFPaneResizeHandleView(frame: .zero)
    private let pdfPaneTitleField = NSTextField(labelWithString: "")
    private let pdfPaneLinkButton = NSButton(title: "Link Selection", target: nil, action: nil)
    private let pdfPaneCloseButton = NSButton(title: "Close", target: nil, action: nil)
    private let pdfPanePDFView = PDFView(frame: .zero)
    private var pdfPaneWidthConstraint: NSLayoutConstraint?
    private var isPDFPaneVisible = false
    private let preferredPDFPaneWidth: CGFloat = 520
    private let minimumPDFPaneWidth: CGFloat = 320
    private let minimumEditorPaneWidth: CGFloat = 440
    private var pdfPaneResizeStartWidth: CGFloat = 0
    private var activePDFContext: (streamId: UUID, sourceId: UUID, sourceName: String, fileURL: URL)?

    deinit {
        NotificationCenter.default.removeObserver(self)
        releaseActivePDFContext()
    }

    override func loadView() {
        view = pdfPaneView
        configurePDFPane()
    }

    func present(url: URL, streamId: UUID, sourceId: UUID, displayName: String) throws {
        if let existing = activePDFContext, existing.sourceId != sourceId {
            releaseActivePDFContext()
        }

        if let existing = activePDFContext, existing.sourceId == sourceId {
            guard setVisible(true) else {
                throw PDFReaderPanePresentationError.notEnoughHorizontalSpace
            }
            url.stopAccessingSecurityScopedResource()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let document = PDFDocument(url: url) else {
            throw PDFReaderPanePresentationError.couldNotOpenPDFSource
        }

        guard setVisible(true) else {
            throw PDFReaderPanePresentationError.notEnoughHorizontalSpace
        }

        pdfPanePDFView.document = document
        pdfPaneTitleField.stringValue = makePDFPaneHeader(displayName)
        pdfPaneLinkButton.isEnabled = false
        activePDFContext = (
            streamId: streamId,
            sourceId: sourceId,
            sourceName: displayName,
            fileURL: url
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func setVisible(_ visible: Bool) -> Bool {
        guard let widthConstraint = pdfPaneWidthConstraint else { return false }

        if visible {
            if isPDFPaneVisible {
                pdfPaneView.isHidden = false
                return true
            }

            let targetWidth = min(preferredPDFPaneWidth, max(minimumPDFPaneWidth, maxAllowedPDFPaneWidth()))
            let grownWidth: CGFloat
            if let window = view.window {
                grownWidth = growMainWindowForPDFPane(window, by: targetWidth)
            } else {
                grownWidth = targetWidth
            }
            guard grownWidth >= minimumPDFPaneWidth else {
                return false
            }

            widthConstraint.constant = grownWidth
            pdfPaneView.isHidden = false
            view.superview?.layoutSubtreeIfNeeded()
            isPDFPaneVisible = true
            return true
        }

        guard isPDFPaneVisible else {
            releaseActivePDFContext()
            return true
        }

        let paneWidth = max(0, widthConstraint.constant)
        widthConstraint.constant = 0
        view.superview?.layoutSubtreeIfNeeded()
        pdfPaneView.isHidden = true
        isPDFPaneVisible = false
        if let window = view.window {
            shrinkMainWindowAfterClosingPDFPane(window, by: paneWidth)
        }
        releaseActivePDFContext()
        return true
    }

    private func configurePDFPane() {
        pdfPaneView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneView.wantsLayer = true
        pdfPaneView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pdfPaneView.isHidden = true

        pdfPaneWidthConstraint = pdfPaneView.widthAnchor.constraint(equalToConstant: 0)
        pdfPaneWidthConstraint?.isActive = true

        let divider = NSView(frame: .zero)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor

        pdfPaneHeaderView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneTitleField.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneLinkButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneCloseButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPanePDFView.translatesAutoresizingMaskIntoConstraints = false

        pdfPaneResizeHandle.wantsLayer = true
        pdfPaneResizeHandle.layer?.backgroundColor = NSColor.clear.cgColor
        pdfPaneResizeHandle.addGestureRecognizer(NSPanGestureRecognizer(
            target: self,
            action: #selector(handlePDFPaneResizePan(_:))
        ))

        pdfPaneTitleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pdfPaneTitleField.lineBreakMode = .byTruncatingTail
        pdfPaneTitleField.maximumNumberOfLines = 1
        pdfPaneTitleField.usesSingleLineMode = true
        pdfPaneTitleField.stringValue = "PDF Source"

        pdfPaneLinkButton.target = self
        pdfPaneLinkButton.action = #selector(handlePDFPaneLinkSelection)
        pdfPaneLinkButton.bezelStyle = .rounded
        pdfPaneLinkButton.controlSize = .small
        pdfPaneLinkButton.isEnabled = false

        pdfPaneCloseButton.target = self
        pdfPaneCloseButton.action = #selector(handlePDFPaneClose)
        pdfPaneCloseButton.bezelStyle = .rounded
        pdfPaneCloseButton.controlSize = .small

        pdfPanePDFView.autoScales = true
        pdfPanePDFView.displayMode = .singlePageContinuous
        pdfPanePDFView.displayDirection = .vertical
        pdfPanePDFView.displaysAsBook = false
        pdfPanePDFView.backgroundColor = NSColor.windowBackgroundColor
        let pageControllerSelector = NSSelectorFromString("usePageViewController:withViewOptions:")
        if pdfPanePDFView.responds(to: pageControllerSelector) {
            pdfPanePDFView.perform(pageControllerSelector, with: NSNumber(value: true), with: nil)
        }

        pdfPaneView.addSubview(divider)
        pdfPaneView.addSubview(pdfPaneResizeHandle)
        pdfPaneView.addSubview(pdfPaneHeaderView)
        pdfPaneView.addSubview(pdfPanePDFView)
        pdfPaneHeaderView.addSubview(pdfPaneTitleField)
        pdfPaneHeaderView.addSubview(pdfPaneLinkButton)
        pdfPaneHeaderView.addSubview(pdfPaneCloseButton)

        NSLayoutConstraint.activate([
            divider.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: pdfPaneView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: pdfPaneView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            pdfPaneResizeHandle.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor),
            pdfPaneResizeHandle.topAnchor.constraint(equalTo: pdfPaneView.topAnchor),
            pdfPaneResizeHandle.bottomAnchor.constraint(equalTo: pdfPaneView.bottomAnchor),
            pdfPaneResizeHandle.widthAnchor.constraint(equalToConstant: 8),

            pdfPaneHeaderView.leadingAnchor.constraint(equalTo: pdfPaneView.leadingAnchor),
            pdfPaneHeaderView.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor, constant: -1),
            pdfPaneHeaderView.topAnchor.constraint(equalTo: pdfPaneView.topAnchor),
            pdfPaneHeaderView.heightAnchor.constraint(equalToConstant: 44),

            pdfPaneTitleField.leadingAnchor.constraint(equalTo: pdfPaneHeaderView.leadingAnchor, constant: 12),
            pdfPaneTitleField.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneTitleField.trailingAnchor.constraint(lessThanOrEqualTo: pdfPaneLinkButton.leadingAnchor, constant: -8),

            pdfPaneCloseButton.trailingAnchor.constraint(equalTo: pdfPaneHeaderView.trailingAnchor, constant: -10),
            pdfPaneCloseButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),

            pdfPaneLinkButton.trailingAnchor.constraint(equalTo: pdfPaneCloseButton.leadingAnchor, constant: -8),
            pdfPaneLinkButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),

            pdfPanePDFView.leadingAnchor.constraint(equalTo: pdfPaneView.leadingAnchor),
            pdfPanePDFView.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor, constant: -8),
            pdfPanePDFView.topAnchor.constraint(equalTo: pdfPaneHeaderView.bottomAnchor),
            pdfPanePDFView.bottomAnchor.constraint(equalTo: pdfPaneView.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePDFPaneSelectionChanged),
            name: Notification.Name.PDFViewSelectionChanged,
            object: pdfPanePDFView
        )
    }

    private func maxAllowedPDFPaneWidth() -> CGFloat {
        let screenWidth = view.window?.screen?.visibleFrame.width
            ?? NSScreen.main?.visibleFrame.width
            ?? preferredPDFPaneWidth
        let screenCap = floor(screenWidth * 0.5)
        let hostWidth = view.superview?.bounds.width ?? view.bounds.width
        let localCap = max(0, hostWidth - minimumEditorPaneWidth)
        return max(minimumPDFPaneWidth, min(screenCap, localCap))
    }

    private func growMainWindowForPDFPane(_ window: NSWindow, by requestedWidth: CGFloat) -> CGFloat {
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let rightEdge = min(window.frame.maxX, screenFrame.maxX - 8)
        let maxWidthAtPosition = rightEdge - (screenFrame.minX + 8)
        let maxGrow = max(0, maxWidthAtPosition - window.frame.width)
        let actualGrow = min(requestedWidth, maxGrow)

        guard actualGrow > 0 else { return 0 }

        var frame = window.frame
        frame.origin.x -= actualGrow
        frame.size.width += actualGrow
        window.setFrame(frame, display: true, animate: true)
        return actualGrow
    }

    private func shrinkMainWindowAfterClosingPDFPane(_ window: NSWindow, by paneWidth: CGFloat) {
        guard paneWidth > 0 else { return }
        let minimumWidth = max(window.minSize.width, 300)
        let maxShrink = max(0, window.frame.width - minimumWidth)
        let actualShrink = min(paneWidth, maxShrink)

        guard actualShrink > 0 else { return }

        var frame = window.frame
        frame.origin.x += actualShrink
        frame.size.width -= actualShrink
        window.setFrame(frame, display: true, animate: true)
    }

    private func clampPDFPaneWidth(_ proposed: CGFloat) -> CGFloat {
        let hardMax = maxAllowedPDFPaneWidth()
        let hostWidth = view.superview?.bounds.width ?? view.bounds.width
        let hostCap = max(0, hostWidth - minimumEditorPaneWidth)
        let maxValue = max(minimumPDFPaneWidth, min(hardMax, hostCap))
        return max(minimumPDFPaneWidth, min(proposed, maxValue))
    }

    private func makePDFPaneHeader(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "PDF Source" }
        if trimmed.count <= 90 { return trimmed }
        let prefix = trimmed.prefix(68)
        let suffix = trimmed.suffix(14)
        return "\(prefix)…\(suffix)"
    }

    private func releaseActivePDFContext() {
        if let current = activePDFContext {
            current.fileURL.stopAccessingSecurityScopedResource()
        }
        activePDFContext = nil
        pdfPanePDFView.document = nil
        pdfPaneTitleField.stringValue = "PDF Source"
        pdfPaneLinkButton.isEnabled = false
    }

    @objc private func handlePDFPaneClose() {
        setVisible(false)
        onClose?()
    }

    @objc private func handlePDFPaneSelectionChanged() {
        let selectedText = pdfPanePDFView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pdfPaneLinkButton.isEnabled = !selectedText.isEmpty
    }

    @objc private func handlePDFPaneResizePan(_ recognizer: NSPanGestureRecognizer) {
        guard isPDFPaneVisible, let widthConstraint = pdfPaneWidthConstraint else { return }

        switch recognizer.state {
        case .began:
            pdfPaneResizeStartWidth = widthConstraint.constant
        case .changed:
            let translation = recognizer.translation(in: view.superview).x
            let next = clampPDFPaneWidth(pdfPaneResizeStartWidth + translation)
            widthConstraint.constant = next
            view.superview?.layoutSubtreeIfNeeded()
        case .ended, .cancelled, .failed:
            widthConstraint.constant = clampPDFPaneWidth(widthConstraint.constant)
            view.superview?.layoutSubtreeIfNeeded()
        default:
            break
        }
    }

    @objc private func handlePDFPaneLinkSelection() {
        guard let context = activePDFContext else {
            NSSound.beep()
            return
        }
        guard let selection = pdfPanePDFView.currentSelection else {
            NSSound.beep()
            return
        }

        let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !quote.isEmpty else {
            NSSound.beep()
            return
        }

        let highlightId = UUID().uuidString
        let firstPage = selection.pages.first
        let pageNumber = firstPage.flatMap { page in
            pdfPanePDFView.document.map { $0.index(for: page) + 1 }
        } ?? 1

        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.32)
            annotation.userName = "Ticker-Next"
            annotation.contents = quote
            page.addAnnotation(annotation)
        }

        onLinkSelection?(PDFHighlightLinkPayload(
            streamId: context.streamId,
            sourceId: context.sourceId,
            sourceName: context.sourceName,
            highlightId: highlightId,
            page: pageNumber,
            quote: quote
        ))
    }
}
