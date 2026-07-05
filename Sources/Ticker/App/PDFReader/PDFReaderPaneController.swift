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
    static let trafficLightSafeLeading: CGFloat = 84

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

struct PDFCitationMatch {
    let selection: PDFSelection
    let page: PDFPage
    let bounds: CGRect
}

enum PDFCitationNavigator {
    static func normalizeQuote(_ quote: String) -> String {
        var normalized = quote
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")

        normalized = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return normalized
    }

    static func match(in document: PDFDocument, chunk: SourceChunk, quote: String?) -> PDFCitationMatch? {
        guard let pageRange = pageRange(for: chunk, pageCount: document.pageCount) else {
            return nil
        }

        guard let quote, !quote.isEmpty else {
            return nil
        }

        let needle = normalizeQuote(quote)
        guard !needle.isEmpty else {
            return nil
        }

        let selections = document.findString(needle, withOptions: .caseInsensitive)
        for selection in selections {
            guard let page = firstPage(in: selection, document: document, pageRange: pageRange) else {
                continue
            }

            let bounds = selection.bounds(for: page)
            guard bounds.isFiniteAndNonEmpty else {
                continue
            }

            return PDFCitationMatch(selection: selection, page: page, bounds: bounds)
        }
        return nil
    }

    static func fallbackPage(for chunk: SourceChunk, requestedPage: Int?) -> Int {
        requestedPage ?? chunk.pageStart
    }

    static func pageRange(for chunk: SourceChunk, pageCount: Int) -> ClosedRange<Int>? {
        guard pageCount > 0 else { return nil }
        let start = max(1, min(chunk.pageStart, chunk.pageEnd))
        let end = min(pageCount, max(chunk.pageStart, chunk.pageEnd))
        guard start <= end else { return nil }
        return start...end
    }

    private static func firstPage(
        in selection: PDFSelection,
        document: PDFDocument,
        pageRange: ClosedRange<Int>
    ) -> PDFPage? {
        selection.pages
            .filter { page in
                let pageNumber = document.index(for: page) + 1
                return pageRange.contains(pageNumber)
            }
            .sorted { lhs, rhs in
                document.index(for: lhs) < document.index(for: rhs)
            }
            .first
    }
}

private extension CGRect {
    var isFiniteAndNonEmpty: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && width > 0
            && height > 0
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
    var onAnchorPlaced: ((PDFHighlightLinkPayload) -> Void)?
    var onAnchorPickCancelled: ((UUID) -> Void)?
    var highlightsProvider: ((UUID) -> [PDFHighlightRecord])?
    var onClose: (() -> Void)?

    private let pdfPaneView = NSView(frame: .zero)
    private let pdfPaneHeaderView = NSView(frame: .zero)
    private let pdfPaneResizeHandle = PDFPaneResizeHandleView(frame: .zero)
    private let pdfPaneTitleField = NSTextField(labelWithString: "")
    private let pdfPaneStatusField = NSTextField(labelWithString: "")
    private let pdfPaneHintIconView = NSImageView(frame: .zero)
    private let pdfPaneLinkButton = NSButton(title: "", target: nil, action: nil)
    private let pdfPaneCloseButton = NSButton(title: "", target: nil, action: nil)
    private let pdfPanePDFView = PDFView(frame: .zero)
    private var pdfPaneWidthConstraint: NSLayoutConstraint?
    private var pdfPaneStatusLeadingConstraint: NSLayoutConstraint?
    private var pdfPaneStatusHintLeadingConstraint: NSLayoutConstraint?
    private var isPDFPaneVisible = false
    private let preferredPDFPaneWidth: CGFloat = 520
    private let minimumPDFPaneWidth: CGFloat = 320
    private let minimumEditorPaneWidth: CGFloat = 440
    private var pdfPaneResizeStartWidth: CGFloat = 0
    private var activePDFContext: (streamId: UUID, sourceId: UUID, sourceName: String, fileURL: URL)?
    private var isAnchorPickMode = false
    private var anchorPickMouseMonitor: Any?
    private var anchorPickKeyMonitor: Any?
    private var anchorPickCursorMonitor: Any?
    private var anchorPickPreviousAcceptsMouseMovedEvents: Bool?

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
        setPDFPaneLinkButtonEnabled(false)
        updatePDFPaneStatus()
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
        setPDFPaneLinkButtonEnabled(false)
        updatePDFPaneStatus()
        pdfPanePDFView.enclosingScrollView?.documentCursor = .crosshair

        anchorPickPreviousAcceptsMouseMovedEvents = view.window?.acceptsMouseMovedEvents
        view.window?.acceptsMouseMovedEvents = true
        anchorPickCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.enforceAnchorPickCursor(for: event)
            return event
        }
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

    func navigateToDestination(highlightId: String?, page pageNumber: Int?, chunk: SourceChunk?, quote: String?) {
        if let chunk {
            navigateToCitationChunk(chunk, fallbackPage: pageNumber, quote: quote)
            return
        }

        navigateToHighlight(id: highlightId, page: pageNumber)
    }

    func removeHighlightAnnotations(ids: [String]) {
        guard !ids.isEmpty,
              let document = pdfPanePDFView.document else {
            return
        }

        let tags = Set(ids.map { id in
            let normalizedId = UUID(uuidString: id)?.uuidString ?? id
            return "\(PDFHighlightAnnotationStyle.contentsPrefix)\(normalizedId)"
        })
        var didRemove = false

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let annotations = page.annotations
            for annotation in annotations where annotation.contents.map(tags.contains) == true {
                page.removeAnnotation(annotation)
                didRemove = true
            }
        }

        if didRemove {
            pdfPanePDFView.needsDisplay = true
        }
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
        pdfPaneStatusField.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneHintIconView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneLinkButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneCloseButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPanePDFView.translatesAutoresizingMaskIntoConstraints = false

        pdfPaneResizeHandle.wantsLayer = true
        pdfPaneResizeHandle.layer?.backgroundColor = NSColor.clear.cgColor
        pdfPaneResizeHandle.addGestureRecognizer(NSPanGestureRecognizer(
            target: self,
            action: #selector(handlePDFPaneResizePan(_:))
        ))

        pdfPaneTitleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        pdfPaneTitleField.textColor = PDFPaneStyle.text
        pdfPaneTitleField.lineBreakMode = .byTruncatingMiddle
        pdfPaneTitleField.maximumNumberOfLines = 1
        pdfPaneTitleField.usesSingleLineMode = true
        pdfPaneTitleField.stringValue = "PDF Source"
        pdfPaneTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pdfPaneTitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pdfPaneStatusField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        pdfPaneStatusField.textColor = PDFPaneStyle.textMuted
        pdfPaneStatusField.lineBreakMode = .byTruncatingTail
        pdfPaneStatusField.maximumNumberOfLines = 1
        pdfPaneStatusField.usesSingleLineMode = true
        pdfPaneStatusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pdfPaneStatusField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pdfPaneHintIconView.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        pdfPaneHintIconView.imageScaling = .scaleProportionallyDown
        pdfPaneHintIconView.contentTintColor = PDFPaneStyle.accent
        pdfPaneHintIconView.isHidden = true

        pdfPaneLinkButton.target = self
        pdfPaneLinkButton.action = #selector(handlePDFPaneLinkSelection)
        pdfPaneLinkButton.bezelStyle = .texturedRounded
        pdfPaneLinkButton.controlSize = .small
        pdfPaneLinkButton.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        pdfPaneLinkButton.imagePosition = .imageOnly
        pdfPaneLinkButton.imageScaling = .scaleProportionallyDown
        pdfPaneLinkButton.isBordered = true
        pdfPaneLinkButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneLinkButton.toolTip = "Link selection to stream"
        pdfPaneLinkButton.setAccessibilityLabel("Link selection to stream")
        pdfPaneLinkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfPaneLinkButton.setContentHuggingPriority(.required, for: .horizontal)
        setPDFPaneLinkButtonEnabled(false)

        pdfPaneCloseButton.target = self
        pdfPaneCloseButton.action = #selector(handlePDFPaneClose)
        pdfPaneCloseButton.bezelStyle = .texturedRounded
        pdfPaneCloseButton.controlSize = .small
        pdfPaneCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        pdfPaneCloseButton.imagePosition = .imageOnly
        pdfPaneCloseButton.imageScaling = .scaleProportionallyDown
        pdfPaneCloseButton.isBordered = true
        pdfPaneCloseButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneCloseButton.contentTintColor = PDFPaneStyle.textMuted
        pdfPaneCloseButton.toolTip = "Close PDF"
        pdfPaneCloseButton.setAccessibilityLabel("Close PDF")
        pdfPaneCloseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfPaneCloseButton.setContentHuggingPriority(.required, for: .horizontal)

        pdfPanePDFView.autoScales = true
        pdfPanePDFView.displayMode = .singlePageContinuous
        pdfPanePDFView.displayDirection = .vertical
        pdfPanePDFView.displaysAsBook = false
        pdfPanePDFView.backgroundColor = PDFPaneStyle.surface
        let pageControllerSelector = NSSelectorFromString("usePageViewController:withViewOptions:")
        if pdfPanePDFView.responds(to: pageControllerSelector) {
            pdfPanePDFView.perform(pageControllerSelector, with: NSNumber(value: true), with: nil)
        }

        let headerSeparator = NSView(frame: .zero)
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.wantsLayer = true
        headerSeparator.layer?.backgroundColor = PDFPaneStyle.separator.cgColor

        pdfPaneView.addSubview(divider)
        pdfPaneView.addSubview(pdfPaneResizeHandle)
        pdfPaneView.addSubview(pdfPaneHeaderView)
        pdfPaneView.addSubview(pdfPanePDFView)
        pdfPaneHeaderView.addSubview(pdfPaneTitleField)
        pdfPaneHeaderView.addSubview(pdfPaneHintIconView)
        pdfPaneHeaderView.addSubview(pdfPaneStatusField)
        pdfPaneHeaderView.addSubview(pdfPaneLinkButton)
        pdfPaneHeaderView.addSubview(pdfPaneCloseButton)
        pdfPaneHeaderView.addSubview(headerSeparator)

        pdfPaneStatusLeadingConstraint = pdfPaneStatusField.leadingAnchor.constraint(
            equalTo: pdfPaneTitleField.leadingAnchor
        )
        pdfPaneStatusHintLeadingConstraint = pdfPaneStatusField.leadingAnchor.constraint(
            equalTo: pdfPaneHintIconView.trailingAnchor,
            constant: 4
        )
        pdfPaneStatusLeadingConstraint?.isActive = true

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

            pdfPaneTitleField.leadingAnchor.constraint(
                equalTo: pdfPaneHeaderView.leadingAnchor,
                constant: PDFPaneStyle.trafficLightSafeLeading
            ),
            pdfPaneTitleField.topAnchor.constraint(equalTo: pdfPaneHeaderView.topAnchor, constant: 6),
            pdfPaneTitleField.trailingAnchor.constraint(lessThanOrEqualTo: pdfPaneLinkButton.leadingAnchor, constant: -10),

            pdfPaneHintIconView.leadingAnchor.constraint(equalTo: pdfPaneTitleField.leadingAnchor),
            pdfPaneHintIconView.centerYAnchor.constraint(equalTo: pdfPaneStatusField.centerYAnchor),
            pdfPaneHintIconView.widthAnchor.constraint(equalToConstant: 12),
            pdfPaneHintIconView.heightAnchor.constraint(equalToConstant: 12),

            pdfPaneStatusField.topAnchor.constraint(equalTo: pdfPaneTitleField.bottomAnchor, constant: 1),
            pdfPaneStatusField.trailingAnchor.constraint(lessThanOrEqualTo: pdfPaneLinkButton.leadingAnchor, constant: -10),
            pdfPaneStatusField.bottomAnchor.constraint(lessThanOrEqualTo: pdfPaneHeaderView.bottomAnchor, constant: -5),

            pdfPaneCloseButton.trailingAnchor.constraint(equalTo: pdfPaneHeaderView.trailingAnchor, constant: -10),
            pdfPaneCloseButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneCloseButton.widthAnchor.constraint(equalToConstant: 28),
            pdfPaneCloseButton.heightAnchor.constraint(equalToConstant: 28),

            pdfPaneLinkButton.trailingAnchor.constraint(equalTo: pdfPaneCloseButton.leadingAnchor, constant: -8),
            pdfPaneLinkButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneLinkButton.widthAnchor.constraint(equalToConstant: 28),
            pdfPaneLinkButton.heightAnchor.constraint(equalToConstant: 28),

            headerSeparator.leadingAnchor.constraint(equalTo: pdfPaneHeaderView.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: pdfPaneHeaderView.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: pdfPaneHeaderView.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePDFPanePageChanged),
            name: Notification.Name.PDFViewPageChanged,
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
        return trimmed.isEmpty ? "PDF Source" : trimmed
    }

    private func releaseActivePDFContext() {
        exitAnchorPickMode(notifyCancelled: false)
        if let current = activePDFContext {
            current.fileURL.stopAccessingSecurityScopedResource()
        }
        activePDFContext = nil
        pdfPanePDFView.document = nil
        pdfPaneTitleField.stringValue = "PDF Source"
        setPDFPaneLinkButtonEnabled(false)
        updatePDFPaneStatus()
    }

    @objc private func handlePDFPaneClose() {
        setVisible(false)
        onClose?()
    }

    @objc private func handlePDFPaneSelectionChanged() {
        guard !isAnchorPickMode else {
            setPDFPaneLinkButtonEnabled(false)
            return
        }
        let selectedText = pdfPanePDFView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        setPDFPaneLinkButtonEnabled(!selectedText.isEmpty)
    }

    @objc private func handlePDFPanePageChanged() {
        updatePDFPaneStatus()
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

    private func navigateToCitationChunk(_ chunk: SourceChunk, fallbackPage pageNumber: Int?, quote: String?) {
        guard let document = pdfPanePDFView.document,
              let match = PDFCitationNavigator.match(in: document, chunk: chunk, quote: quote) else {
            navigate(toPageNumber: PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: pageNumber))
            return
        }

        navigate(to: match.bounds, on: match.page)
        if let pageRange = PDFCitationNavigator.pageRange(for: chunk, pageCount: document.pageCount) {
            flashCitationSelection(match.selection, pageRange: pageRange)
        }
    }

    private func navigate(to rect: CGRect, on page: PDFPage) {
        let visibleHeight = pdfPanePDFView.convert(pdfPanePDFView.bounds, to: page).height
        let pageBounds = page.bounds(for: .mediaBox)
        let destinationY: CGFloat

        if visibleHeight.isFinite,
           visibleHeight > 0,
           pageBounds.minY.isFinite,
           pageBounds.maxY.isFinite,
           pageBounds.minY < pageBounds.maxY {
            let centeredY = rect.midY + visibleHeight / 2
            destinationY = min(max(centeredY, pageBounds.minY), pageBounds.maxY)
        } else {
            destinationY = rect.maxY
        }

        let destination = PDFDestination(page: page, at: CGPoint(x: rect.minX, y: destinationY))
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
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
        pdfPanePDFView.go(to: destination)
    }

    private func pulseAnnotations(_ annotations: [PDFAnnotation], removeAfterPulse: Bool = false) {
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
            if removeAfterPulse {
                annotations.forEach { annotation in
                    annotation.page?.removeAnnotation(annotation)
                }
            } else {
                for ((annotation, color), interiorColor) in zip(zip(annotations, originalColors), originalInteriorColors) {
                    annotation.color = color
                    annotation.interiorColor = interiorColor
                }
            }
            self?.pdfPanePDFView.needsDisplay = true
        }
    }

    private func flashCitationSelection(_ selection: PDFSelection, pageRange: ClosedRange<Int>) {
        guard let document = pdfPanePDFView.document else { return }

        let lineSelections = selection.selectionsByLine()
        let selections = lineSelections.isEmpty ? [selection] : lineSelections
        var annotations: [PDFAnnotation] = []

        for lineSelection in selections {
            for page in lineSelection.pages {
                let pageNumber = document.index(for: page) + 1
                guard pageRange.contains(pageNumber) else {
                    continue
                }

                let bounds = lineSelection.bounds(for: page)
                guard bounds.isFiniteAndNonEmpty else {
                    continue
                }

                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = PDFHighlightAnnotationStyle.color
                annotation.userName = "Ticker-Next"
                page.addAnnotation(annotation)
                annotations.append(annotation)
            }
        }

        pulseAnnotations(annotations, removeAfterPulse: true)
    }

    private func handleAnchorPickMouseDown(_ event: NSEvent) -> NSEvent? {
        guard isAnchorPickMode else { return event }

        let pointInPDFView = pdfPanePDFView.convert(event.locationInWindow, from: nil)
        guard pdfPanePDFView.bounds.contains(pointInPDFView) else {
            cancelAnchorPickMode()
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

    private func enforceAnchorPickCursor(for event: NSEvent) {
        guard isAnchorPickMode else { return }
        let pointInPDFView = pdfPanePDFView.convert(event.locationInWindow, from: nil)
        guard pdfPanePDFView.bounds.contains(pointInPDFView) else { return }
        NSCursor.crosshair.set()
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
        guard isAnchorPickMode ||
            anchorPickMouseMonitor != nil ||
            anchorPickKeyMonitor != nil ||
            anchorPickCursorMonitor != nil ||
            anchorPickPreviousAcceptsMouseMovedEvents != nil else {
            return
        }
        let streamId = activePDFContext?.streamId

        if let anchorPickCursorMonitor {
            NSEvent.removeMonitor(anchorPickCursorMonitor)
            self.anchorPickCursorMonitor = nil
        }
        if let anchorPickMouseMonitor {
            NSEvent.removeMonitor(anchorPickMouseMonitor)
            self.anchorPickMouseMonitor = nil
        }
        if let anchorPickKeyMonitor {
            NSEvent.removeMonitor(anchorPickKeyMonitor)
            self.anchorPickKeyMonitor = nil
        }

        if let previousAcceptsMouseMovedEvents = anchorPickPreviousAcceptsMouseMovedEvents {
            view.window?.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
            anchorPickPreviousAcceptsMouseMovedEvents = nil
        }
        isAnchorPickMode = false
        pdfPanePDFView.enclosingScrollView?.documentCursor = nil
        if let context = activePDFContext {
            pdfPaneTitleField.stringValue = makePDFPaneHeader(context.sourceName)
        } else {
            pdfPaneTitleField.stringValue = "PDF Source"
        }
        pdfPaneTitleField.textColor = PDFPaneStyle.text
        updatePDFPaneStatus()
        handlePDFPaneSelectionChanged()

        if notifyCancelled, let streamId {
            onAnchorPickCancelled?(streamId)
        }
    }

    private func setPDFPaneLinkButtonEnabled(_ enabled: Bool) {
        pdfPaneLinkButton.isEnabled = enabled
        pdfPaneLinkButton.contentTintColor = enabled ? PDFPaneStyle.accent : PDFPaneStyle.textMuted
    }

    private func updatePDFPaneStatus() {
        let pageText = pdfPanePageText()
        let showHint = isAnchorPickMode
        let hintText = "Click a spot to link · Esc to cancel"

        pdfPaneHintIconView.isHidden = !showHint
        pdfPaneStatusLeadingConstraint?.isActive = !showHint
        pdfPaneStatusHintLeadingConstraint?.isActive = showHint
        pdfPaneStatusField.stringValue = showHint
            ? [pageText, hintText].filter { !$0.isEmpty }.joined(separator: " · ")
            : pageText
    }

    private func pdfPanePageText() -> String {
        guard let document = pdfPanePDFView.document,
              document.pageCount > 0 else {
            return ""
        }

        let page = pdfPanePDFView.currentPage ?? document.page(at: 0)
        let current = page.map { max(1, document.index(for: $0) + 1) } ?? 1
        return "p. \(current) / \(document.pageCount)"
    }
}
