import AppKit
import PDFKit

struct PDFHighlightLinkPayload {
    let streamId: UUID
    let sourceName: String
    let highlight: PDFHighlightRecord
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

private enum PDFPaneStyle {
    static let background = dynamicColor(
        light: NSColor(red: 251 / 255, green: 251 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(red: 28 / 255, green: 28 / 255, blue: 27 / 255, alpha: 1)
    )
    static let surface = dynamicColor(
        light: NSColor(red: 244 / 255, green: 244 / 255, blue: 242 / 255, alpha: 1),
        dark: NSColor(red: 36 / 255, green: 36 / 255, blue: 35 / 255, alpha: 1)
    )
    static let text = dynamicColor(
        light: NSColor(red: 31 / 255, green: 31 / 255, blue: 29 / 255, alpha: 1),
        dark: NSColor(red: 243 / 255, green: 242 / 255, blue: 237 / 255, alpha: 1)
    )
    static let textMuted = dynamicColor(
        light: NSColor(red: 111 / 255, green: 111 / 255, blue: 104 / 255, alpha: 1),
        dark: NSColor(red: 170 / 255, green: 167 / 255, blue: 157 / 255, alpha: 1)
    )
    static let accent = dynamicColor(
        light: NSColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1),
        dark: NSColor(red: 138 / 255, green: 168 / 255, blue: 255 / 255, alpha: 1)
    )
    static let separator = dynamicColor(
        light: NSColor(red: 31 / 255, green: 31 / 255, blue: 29 / 255, alpha: 0.08),
        dark: NSColor(red: 243 / 255, green: 242 / 255, blue: 237 / 255, alpha: 0.08)
    )

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return dark
            default:
                return light
            }
        }
    }
}

private enum PDFHighlightAnnotationStyle {
    static let contentsPrefix = "ticker-pdf-highlight:"
    static let color = NSColor.systemYellow.withAlphaComponent(0.32)
    static let pulseColor = NSColor.systemYellow.withAlphaComponent(0.62)
    static let markerColor = PDFPaneStyle.accent.withAlphaComponent(0.38)
    static let markerPulseColor = PDFPaneStyle.accent.withAlphaComponent(0.74)
    static let markerSize: CGFloat = 14
    static let escapeKeyCode: UInt16 = 53
}

private final class PDFPaneResizeHandleView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

final class PDFReaderPaneController: NSViewController {
    var onLinkSelection: ((PDFHighlightLinkPayload) -> Void)?
    var onAnchorPlaced: ((PDFHighlightLinkPayload) -> Void)?
    var onAnchorPickCancelled: ((UUID) -> Void)?
    var highlightsProvider: ((UUID) -> [PDFHighlightRecord])?
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
    private var isAnchorPickMode = false
    private var anchorPickMouseMonitor: Any?
    private var anchorPickKeyMonitor: Any?

    deinit {
        NotificationCenter.default.removeObserver(self)
        exitAnchorPickMode(notifyCancelled: false)
        releaseActivePDFContext()
    }

    override func loadView() {
        view = pdfPaneView
        configurePDFPane()
    }

    func present(url: URL, streamId: UUID, sourceId: UUID, displayName: String) throws {
        if let existing = activePDFContext, existing.sourceId != sourceId {
            exitAnchorPickMode(notifyCancelled: true)
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
        applySavedHighlights(sourceId: sourceId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func isPresenting(sourceId: UUID) -> Bool {
        activePDFContext?.sourceId == sourceId && isPDFPaneVisible
    }

    func isPresenting(streamId: UUID) -> Bool {
        activePDFContext?.streamId == streamId && isPDFPaneVisible
    }

    func beginAnchorPickMode() -> Bool {
        guard activePDFContext != nil, isPDFPaneVisible else { return false }
        exitAnchorPickMode(notifyCancelled: false)

        isAnchorPickMode = true
        pdfPaneTitleField.stringValue = "Click a spot to link · Esc to cancel"
        pdfPaneTitleField.textColor = PDFPaneStyle.accent
        pdfPaneLinkButton.isEnabled = false
        pdfPanePDFView.enclosingScrollView?.documentCursor = .crosshair

        anchorPickMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleAnchorPickMouseDown(event) ?? event
        }
        anchorPickKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isAnchorPickMode, event.keyCode == PDFHighlightAnnotationStyle.escapeKeyCode {
                self.cancelAnchorPickMode()
                return nil
            }
            return event
        }

        return true
    }

    func cancelAnchorPickMode() {
        exitAnchorPickMode(notifyCancelled: true)
    }

    func navigateToHighlight(id highlightId: String?, page pageNumber: Int?) {
        if let highlightId, !highlightId.isEmpty {
            var annotations = taggedAnnotations(highlightId: highlightId)
            if annotations.isEmpty, let record = savedHighlight(id: highlightId) {
                applyHighlight(record)
                annotations = taggedAnnotations(highlightId: highlightId)
            }

            if let first = firstAnnotationForNavigation(annotations) {
                navigate(to: first.annotation.bounds, on: first.page)
                pulseAnnotations(annotations)
                return
            }
        }

        navigate(toPageNumber: pageNumber)
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
            exitAnchorPickMode(notifyCancelled: true)
            releaseActivePDFContext()
            return true
        }

        exitAnchorPickMode(notifyCancelled: true)
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
        pdfPaneView.layer?.backgroundColor = PDFPaneStyle.background.cgColor
        pdfPaneView.isHidden = true

        pdfPaneWidthConstraint = pdfPaneView.widthAnchor.constraint(equalToConstant: 0)
        pdfPaneWidthConstraint?.isActive = true

        let divider = NSView(frame: .zero)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = PDFPaneStyle.separator.cgColor

        pdfPaneHeaderView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneHeaderView.wantsLayer = true
        pdfPaneHeaderView.layer?.backgroundColor = PDFPaneStyle.background.cgColor
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

        pdfPaneTitleField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        pdfPaneTitleField.textColor = PDFPaneStyle.text
        pdfPaneTitleField.lineBreakMode = .byTruncatingTail
        pdfPaneTitleField.maximumNumberOfLines = 1
        pdfPaneTitleField.usesSingleLineMode = true
        pdfPaneTitleField.stringValue = "PDF Source"

        pdfPaneLinkButton.target = self
        pdfPaneLinkButton.action = #selector(handlePDFPaneLinkSelection)
        pdfPaneLinkButton.bezelStyle = .rounded
        pdfPaneLinkButton.controlSize = .small
        pdfPaneLinkButton.isEnabled = false
        pdfPaneLinkButton.contentTintColor = PDFPaneStyle.accent

        pdfPaneCloseButton.target = self
        pdfPaneCloseButton.action = #selector(handlePDFPaneClose)
        pdfPaneCloseButton.bezelStyle = .rounded
        pdfPaneCloseButton.controlSize = .small
        pdfPaneCloseButton.contentTintColor = PDFPaneStyle.textMuted

        pdfPanePDFView.autoScales = true
        pdfPanePDFView.displayMode = .singlePageContinuous
        pdfPanePDFView.displayDirection = .vertical
        pdfPanePDFView.displaysAsBook = false
        pdfPanePDFView.backgroundColor = PDFPaneStyle.surface
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
        exitAnchorPickMode(notifyCancelled: false)
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
        guard !isAnchorPickMode else {
            pdfPaneLinkButton.isEnabled = false
            return
        }
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
        exitAnchorPickMode(notifyCancelled: true)

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

        let rects = highlightRects(for: selection)
        guard let firstRect = rects.first else {
            NSSound.beep()
            return
        }

        let highlight = PDFHighlightRecord(
            id: UUID(),
            sourceId: context.sourceId,
            page: firstRect.page,
            rects: rects,
            quote: quote,
            createdAt: Date()
        )
        applyHighlight(highlight)

        onLinkSelection?(PDFHighlightLinkPayload(
            streamId: context.streamId,
            sourceName: context.sourceName,
            highlight: highlight
        ))
    }

    private func highlightRects(for selection: PDFSelection) -> [PDFHighlightRect] {
        guard let document = pdfPanePDFView.document else { return [] }
        let lineSelections = selection.selectionsByLine()
        let selections = lineSelections.isEmpty ? [selection] : lineSelections

        return selections.flatMap { lineSelection in
            lineSelection.pages.compactMap { page -> PDFHighlightRect? in
                let bounds = lineSelection.bounds(for: page).standardized
                guard bounds.width > 0, bounds.height > 0 else { return nil }

                return PDFHighlightRect(
                    page: document.index(for: page) + 1,
                    x: Double(bounds.minX),
                    y: Double(bounds.minY),
                    w: Double(bounds.width),
                    h: Double(bounds.height)
                )
            }
        }
    }

    private func applySavedHighlights(sourceId: UUID) {
        guard let highlightsProvider else { return }
        for highlight in highlightsProvider(sourceId) {
            applyHighlight(highlight)
        }
    }

    private func savedHighlight(id highlightId: String) -> PDFHighlightRecord? {
        guard let sourceId = activePDFContext?.sourceId,
              let highlightsProvider else {
            return nil
        }

        return highlightsProvider(sourceId).first { $0.id.uuidString == highlightId }
    }

    private func applyHighlight(_ highlight: PDFHighlightRecord) {
        guard let document = pdfPanePDFView.document else { return }
        let isPointAnchor = highlight.quote.isEmpty && highlight.rects.count == 1

        for rect in highlight.rects {
            guard rect.page > 0,
                  let page = document.page(at: rect.page - 1) else {
                continue
            }

            let bounds = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: isPointAnchor ? .circle : .highlight,
                withProperties: nil
            )
            annotation.color = isPointAnchor
                ? PDFHighlightAnnotationStyle.markerColor
                : PDFHighlightAnnotationStyle.color
            if isPointAnchor {
                annotation.interiorColor = PDFHighlightAnnotationStyle.markerColor
            }
            annotation.userName = "Ticker-Next"
            annotation.contents = "\(PDFHighlightAnnotationStyle.contentsPrefix)\(highlight.id.uuidString)"
            page.addAnnotation(annotation)
        }
    }

    private func taggedAnnotations(highlightId: String) -> [PDFAnnotation] {
        guard let document = pdfPanePDFView.document else { return [] }
        let tag = "\(PDFHighlightAnnotationStyle.contentsPrefix)\(highlightId)"
        var annotations: [PDFAnnotation] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            annotations.append(contentsOf: page.annotations.filter { $0.contents == tag })
        }

        return annotations
    }

    private func firstAnnotationForNavigation(_ annotations: [PDFAnnotation]) -> (annotation: PDFAnnotation, page: PDFPage)? {
        guard let document = pdfPanePDFView.document else { return nil }

        return annotations
            .compactMap { annotation -> (annotation: PDFAnnotation, page: PDFPage, pageIndex: Int)? in
                guard let page = annotation.page else { return nil }
                return (annotation, page, document.index(for: page))
            }
            .sorted { lhs, rhs in
                if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
                return lhs.annotation.bounds.maxY > rhs.annotation.bounds.maxY
            }
            .first
            .map { ($0.annotation, $0.page) }
    }

    private func navigate(to rect: CGRect, on page: PDFPage) {
        let destination = PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY))
        pdfPanePDFView.go(to: destination)
    }

    private func navigate(toPageNumber pageNumber: Int?) {
        guard let document = pdfPanePDFView.document,
              document.pageCount > 0 else {
            return
        }

        let clampedPage = max(1, min(pageNumber ?? 1, document.pageCount))
        guard let page = document.page(at: clampedPage - 1) else { return }
        let bounds = page.bounds(for: .mediaBox)
        navigate(to: bounds, on: page)
    }

    private func pulseAnnotations(_ annotations: [PDFAnnotation]) {
        guard !annotations.isEmpty else { return }
        let originalColors = annotations.map(\.color)
        let originalInteriorColors = annotations.map(\.interiorColor)
        annotations.forEach {
            if $0.interiorColor != nil {
                $0.color = PDFHighlightAnnotationStyle.markerPulseColor
                $0.interiorColor = PDFHighlightAnnotationStyle.markerPulseColor
            } else {
                $0.color = PDFHighlightAnnotationStyle.pulseColor
            }
        }
        pdfPanePDFView.needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            for ((annotation, color), interiorColor) in zip(zip(annotations, originalColors), originalInteriorColors) {
                annotation.color = color
                annotation.interiorColor = interiorColor
            }
            self?.pdfPanePDFView.needsDisplay = true
        }
    }

    private func handleAnchorPickMouseDown(_ event: NSEvent) -> NSEvent? {
        guard isAnchorPickMode else { return event }

        let pointInPDFView = pdfPanePDFView.convert(event.locationInWindow, from: nil)
        guard pdfPanePDFView.bounds.contains(pointInPDFView) else {
            return event
        }

        placeAnchor(at: pointInPDFView)
        return nil
    }

    private func placeAnchor(at pointInPDFView: CGPoint) {
        guard let context = activePDFContext,
              let document = pdfPanePDFView.document,
              let page = pdfPanePDFView.page(for: pointInPDFView, nearest: true) else {
            NSSound.beep()
            cancelAnchorPickMode()
            return
        }

        let pagePoint = pdfPanePDFView.convert(pointInPDFView, to: page)
        let pageNumber = document.index(for: page) + 1
        let bounds = markerBounds(centeredAt: pagePoint, on: page)
        let highlight = PDFHighlightRecord(
            id: UUID(),
            sourceId: context.sourceId,
            page: pageNumber,
            rects: [
                PDFHighlightRect(
                    page: pageNumber,
                    x: Double(bounds.minX),
                    y: Double(bounds.minY),
                    w: Double(bounds.width),
                    h: Double(bounds.height)
                )
            ],
            quote: "",
            createdAt: Date()
        )

        applyHighlight(highlight)
        exitAnchorPickMode(notifyCancelled: false)
        onAnchorPlaced?(PDFHighlightLinkPayload(
            streamId: context.streamId,
            sourceName: context.sourceName,
            highlight: highlight
        ))
    }

    private func markerBounds(centeredAt point: CGPoint, on page: PDFPage) -> CGRect {
        let size = PDFHighlightAnnotationStyle.markerSize
        let pageBounds = page.bounds(for: .mediaBox)
        let maxX = max(pageBounds.minX, pageBounds.maxX - size)
        let maxY = max(pageBounds.minY, pageBounds.maxY - size)
        let x = min(max(point.x - size / 2, pageBounds.minX), maxX)
        let y = min(max(point.y - size / 2, pageBounds.minY), maxY)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func exitAnchorPickMode(notifyCancelled: Bool) {
        guard isAnchorPickMode || anchorPickMouseMonitor != nil || anchorPickKeyMonitor != nil else { return }
        let streamId = activePDFContext?.streamId

        if let anchorPickMouseMonitor {
            NSEvent.removeMonitor(anchorPickMouseMonitor)
            self.anchorPickMouseMonitor = nil
        }
        if let anchorPickKeyMonitor {
            NSEvent.removeMonitor(anchorPickKeyMonitor)
            self.anchorPickKeyMonitor = nil
        }

        isAnchorPickMode = false
        pdfPanePDFView.enclosingScrollView?.documentCursor = nil
        if let context = activePDFContext {
            pdfPaneTitleField.stringValue = makePDFPaneHeader(context.sourceName)
        } else {
            pdfPaneTitleField.stringValue = "PDF Source"
        }
        pdfPaneTitleField.textColor = PDFPaneStyle.text
        handlePDFPaneSelectionChanged()

        if notifyCancelled, let streamId {
            onAnchorPickCancelled?(streamId)
        }
    }
}
