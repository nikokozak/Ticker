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

enum PDFCitationFallbackAffordance {
    static func shouldShow(chunkPresent: Bool, matchFound: Bool) -> Bool {
        chunkPresent && !matchFound
    }
}

struct PDFFindResults {
    let selections: [PDFSelection]
    let isCapped: Bool
}

enum PDFDocumentFind {
    static let maxMatches = 500

    static func matches(
        in document: PDFDocument,
        query: String,
        limit: Int = maxMatches
    ) -> PDFFindResults {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else {
            return PDFFindResults(selections: [], isCapped: false)
        }

        let selections = document.findString(trimmedQuery, withOptions: .caseInsensitive)
        if selections.count > limit {
            // ponytail: cap protects PDFKit/UI work on huge docs; upgrade path is incremental page-windowed search.
            return PDFFindResults(selections: Array(selections.prefix(limit)), isCapped: true)
        }

        return PDFFindResults(selections: selections, isCapped: false)
    }
}

enum PDFFindNavigation {
    static func nextIndex(currentIndex: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let currentIndex else { return 0 }
        return (currentIndex + 1) % matchCount
    }

    static func previousIndex(currentIndex: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let currentIndex else { return matchCount - 1 }
        return (currentIndex + matchCount - 1) % matchCount
    }
}

struct PDFPaneOpeningLayout: Equatable {
    let targetWindowFrame: CGRect
    let paneWidth: CGFloat
    let shouldResizeWindow: Bool

    /// Accordion semantics: the editor must not change size when the pane
    /// opens. The window widens by exactly the pane width (right edge grows),
    /// slides left only when the screen edge would clip it, and never changes
    /// height or vertical position. The editor only shrinks by whatever width
    /// the screen genuinely cannot provide.
    static func calculate(
        currentFrame: CGRect,
        visibleFrame: CGRect,
        isNativeFullscreen: Bool
    ) -> PDFPaneOpeningLayout {
        let paneWidth = floor(currentFrame.width * 0.5)
        if isNativeFullscreen || currentFrame.width >= visibleFrame.width {
            return PDFPaneOpeningLayout(
                targetWindowFrame: currentFrame,
                paneWidth: paneWidth,
                shouldResizeWindow: false
            )
        }

        let targetWidth = min(currentFrame.width + paneWidth, visibleFrame.width)
        let x = min(max(currentFrame.origin.x, visibleFrame.minX), visibleFrame.maxX - targetWidth)
        let targetFrame = CGRect(
            x: x,
            y: currentFrame.origin.y,
            width: targetWidth,
            height: currentFrame.height
        )

        return PDFPaneOpeningLayout(
            targetWindowFrame: targetFrame,
            paneWidth: paneWidth,
            shouldResizeWindow: targetFrame != currentFrame
        )
    }
}

enum PDFPaneWidthPolicy {
    static let minimumPDFPaneWidth: CGFloat = 320
    static let minimumEditorPaneWidth: CGFloat = 400

    static func maxAllowedPDFPaneWidth(
        hostWidth: CGFloat,
        minimumPDFPaneWidth: CGFloat = Self.minimumPDFPaneWidth,
        minimumEditorPaneWidth: CGFloat = Self.minimumEditorPaneWidth
    ) -> CGFloat {
        let boundedHostWidth = max(0, hostWidth)
        let editorPreservingCap = max(0, boundedHostWidth - minimumEditorPaneWidth)
        return min(boundedHostWidth, max(minimumPDFPaneWidth, editorPreservingCap))
    }

    static func clampPDFPaneWidth(
        _ proposed: CGFloat,
        hostWidth: CGFloat,
        minimumPDFPaneWidth: CGFloat = Self.minimumPDFPaneWidth,
        minimumEditorPaneWidth: CGFloat = Self.minimumEditorPaneWidth
    ) -> CGFloat {
        let maxValue = maxAllowedPDFPaneWidth(
            hostWidth: hostWidth,
            minimumPDFPaneWidth: minimumPDFPaneWidth,
            minimumEditorPaneWidth: minimumEditorPaneWidth
        )
        let minValue = min(minimumPDFPaneWidth, maxValue)
        return min(max(proposed, minValue), maxValue)
    }
}

enum PDFPaneWindowRestore {
    static func targetFrame(savedFrame: CGRect?, isNativeFullscreen: Bool) -> CGRect? {
        isNativeFullscreen ? nil : savedFrame
    }
}

enum PDFCitationNavigator {
    static func normalizeQuote(_ quote: String) -> String {
        NormalizedTextMap.build(from: quote).normalized
    }

    static func verifiedOriginalSpan(in chunkText: String, quote: String?) -> String? {
        guard let quote else { return nil }

        let normalizedQuote = normalizeQuote(quote)
        guard !normalizedQuote.isEmpty else { return nil }

        let chunkMap = NormalizedTextMap.build(from: chunkText)
        guard let normalizedRange = chunkMap.normalized.range(of: normalizedQuote),
              let originalRange = chunkMap.originalRange(for: normalizedRange) else {
            return nil
        }

        return String(chunkText[originalRange])
    }

    static func match(in document: PDFDocument, chunk: SourceChunk, quote: String?) -> PDFCitationMatch? {
        guard let pageRange = pageRange(for: chunk, pageCount: document.pageCount) else {
            return nil
        }

        guard let verifiedSpan = verifiedOriginalSpan(in: chunk.text, quote: quote) else {
            return nil
        }

        for pageNumber in pageRange {
            guard let page = document.page(at: pageNumber - 1),
                  let selection = selection(on: page, matching: verifiedSpan) else { continue }
            let bounds = selection.bounds(for: page)
            guard bounds.isFiniteAndNonEmpty else { continue }

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

    private static func selection(on page: PDFPage, matching verifiedSpan: String) -> PDFSelection? {
        guard let pageText = page.string else { return nil }

        let normalizedSpan = normalizeQuote(verifiedSpan)
        guard !normalizedSpan.isEmpty else { return nil }

        let pageMap = NormalizedTextMap.build(from: pageText)
        guard let normalizedRange = pageMap.normalized.range(of: normalizedSpan),
              let originalRange = pageMap.originalRange(for: normalizedRange) else {
            return nil
        }

        let nsRange = NSRange(originalRange, in: pageText)
        guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
        return page.selection(for: nsRange)
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

/// CALayer colors and PDFView's background are one-shot snapshots, not
/// appearance-dynamic like control text — they must be re-applied whenever the
/// effective appearance (settings theme or system) changes.
private final class PDFPaneAppearanceObservingView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

private final class PDFPaneFindSearchField: NSSearchField {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private struct PDFOutlineSidebarEntry {
    let title: String
    let destination: PDFDestination?
    let depth: Int
}

final class PDFReaderPaneController: NSViewController {
    var onLinkSelection: ((PDFHighlightLinkPayload) -> Void)?
    var onAnchorPlaced: ((PDFHighlightLinkPayload) -> Void)?
    var onAnchorPickCancelled: ((UUID) -> Void)?
    var onPageChanged: ((UUID, Int) -> Void)?
    var highlightsProvider: ((UUID) -> [PDFHighlightRecord])?
    var onClose: (() -> Void)?

    private let pdfPaneView = PDFPaneAppearanceObservingView(frame: .zero)
    private let pdfPaneHeaderView = NSView(frame: .zero)
    private var paneBackgroundLayerViews: [NSView] = []
    private var paneSeparatorLayerViews: [NSView] = []
    private let pdfPaneResizeHandle = PDFPaneResizeHandleView(frame: .zero)
    private let pdfPaneTitleField = NSTextField(labelWithString: "")
    private let pdfPaneStatusField = NSTextField(labelWithString: "")
    private let pdfPaneHintIconView = NSImageView(frame: .zero)
    private let pdfPaneOutlineButton = NSButton(title: "", target: nil, action: nil)
    private let pdfPaneLinkButton = NSButton(title: "", target: nil, action: nil)
    private let pdfPaneCloseButton = NSButton(title: "", target: nil, action: nil)
    private let pdfFindBarView = NSView(frame: .zero)
    private let pdfFindSearchField = PDFPaneFindSearchField(frame: .zero)
    private let pdfFindCounterField = NSTextField(labelWithString: "")
    private let pdfFindPreviousButton = NSButton(title: "", target: nil, action: nil)
    private let pdfFindNextButton = NSButton(title: "", target: nil, action: nil)
    private let pdfOutlineScrollView = NSScrollView(frame: .zero)
    private let pdfOutlineStackView = NSStackView(frame: .zero)
    private let pdfPanePDFView = PDFView(frame: .zero)
    private var pdfPaneWidthConstraint: NSLayoutConstraint?
    private var pdfFindBarHeightConstraint: NSLayoutConstraint?
    private var pdfOutlineWidthConstraint: NSLayoutConstraint?
    private var pdfPaneOutlineButtonWidthConstraint: NSLayoutConstraint?
    private var pdfPaneStatusLeadingConstraint: NSLayoutConstraint?
    private var pdfPaneStatusHintLeadingConstraint: NSLayoutConstraint?
    private var isPDFPaneVisible = false
    private let preferredPDFPaneWidth: CGFloat = 520
    private let minimumPDFPaneWidth = PDFPaneWidthPolicy.minimumPDFPaneWidth
    private let minimumEditorPaneWidth = PDFPaneWidthPolicy.minimumEditorPaneWidth
    private var pdfPaneResizeStartWidth: CGFloat = 0
    private var prePDFPaneWindowFrame: CGRect?
    private var activePDFContext: (streamId: UUID, sourceId: UUID, sourceName: String, fileURL: URL)?
    private var isAnchorPickMode = false
    private var anchorPickMouseMonitor: Any?
    private var anchorPickKeyMonitor: Any?
    private var anchorPickCursorMonitor: Any?
    private var anchorPickPreviousAcceptsMouseMovedEvents: Bool?
    private var pdfFindDebounceWorkItem: DispatchWorkItem?
    private var pdfFindGeneration = 0
    private var pdfFindMatches: [PDFSelection] = []
    private var pdfFindCurrentIndex: Int?
    private var pdfFindIsCapped = false
    private var pdfPageSaveWorkItem: DispatchWorkItem?
    private var pdfPaneMessageWorkItem: DispatchWorkItem?
    private var pdfPaneTransientMessage: String?
    private var pdfOutlineEntries: [PDFOutlineSidebarEntry] = []
    private var isPDFOutlineVisible = false

    deinit {
        pdfFindDebounceWorkItem?.cancel()
        pdfPageSaveWorkItem?.cancel()
        pdfPaneMessageWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        exitAnchorPickMode(notifyCancelled: false)
        releaseActivePDFContext()
    }

    override func loadView() {
        view = pdfPaneView
        configurePDFPane()
    }

    func present(url: URL, streamId: UUID, sourceId: UUID, displayName: String, lastPageIndex: Int? = nil) throws {
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
        configurePDFOutline(document: document)
        setPDFPaneHeader(displayName: displayName)
        setPDFPaneLinkButtonEnabled(false)
        updatePDFPaneStatus()
        activePDFContext = (
            streamId: streamId,
            sourceId: sourceId,
            sourceName: displayName,
            fileURL: url
        )
        applySavedHighlights(sourceId: sourceId)
        if let lastPageIndex {
            navigate(toPageIndex: lastPageIndex)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func isPresenting(sourceId: UUID) -> Bool {
        activePDFContext?.sourceId == sourceId && isPDFPaneVisible
    }

    func isPresenting(streamId: UUID) -> Bool {
        activePDFContext?.streamId == streamId && isPDFPaneVisible
    }

    func currentSelectedText() -> String? {
        guard isPDFPaneVisible else { return nil }
        let selectedText = pdfPanePDFView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selectedText.isEmpty ? nil : selectedText
    }

    func handleFindShortcutIfFocused() -> Bool {
        guard isPDFPaneVisible,
              view.window?.isKeyWindow == true,
              firstResponderIsInPDFPane() else {
            return false
        }

        showPDFFindBar()
        return true
    }

    func handleFindBarKeyEvent(_ event: NSEvent) -> Bool {
        guard isPDFPaneVisible,
              !pdfFindBarView.isHidden,
              firstResponderIsInPDFFindBar() else {
            return false
        }

        return handlePDFFindKeyDown(event)
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

            let paneWidth: CGFloat
            var targetWindowFrame: CGRect?
            var shouldResizeWindow = false

            if let window = view.window {
                let isFullscreen = window.styleMask.contains(.fullScreen)
                if prePDFPaneWindowFrame == nil, !isFullscreen {
                    prePDFPaneWindowFrame = window.frame
                }
                let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
                let layout = PDFPaneOpeningLayout.calculate(
                    currentFrame: window.frame,
                    visibleFrame: screenFrame,
                    isNativeFullscreen: isFullscreen
                )
                paneWidth = layout.paneWidth
                targetWindowFrame = layout.targetWindowFrame
                shouldResizeWindow = layout.shouldResizeWindow
            } else {
                paneWidth = preferredPDFPaneWidth
            }

            guard paneWidth >= minimumPDFPaneWidth else {
                prePDFPaneWindowFrame = nil
                return false
            }

            pdfPaneView.isHidden = false
            isPDFPaneVisible = true

            // Pane width and window frame animate in ONE group. Sequenced
            // separately (constraint instantly, frame after), the editor first
            // squeezes inside the old frame and the window then visibly warps
            // to the screen edge.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.allowsImplicitAnimation = true
                widthConstraint.animator().constant = paneWidth
                if shouldResizeWindow,
                   let window = view.window,
                   let targetWindowFrame {
                    window.animator().setFrame(targetWindowFrame, display: true)
                }
                view.superview?.layoutSubtreeIfNeeded()
            }
            return true
        }

        guard isPDFPaneVisible else {
            exitAnchorPickMode(notifyCancelled: true)
            releaseActivePDFContext()
            return true
        }

        exitAnchorPickMode(notifyCancelled: true)
        dismissPDFFindBar(clearQuery: true, restoreFocus: false)
        let restoreFrame = PDFPaneWindowRestore.targetFrame(
            savedFrame: prePDFPaneWindowFrame,
            isNativeFullscreen: view.window?.styleMask.contains(.fullScreen) == true
        )
        prePDFPaneWindowFrame = nil
        isPDFPaneVisible = false
        // Mirror of the open animation; the document stays rendered while the
        // pane slides closed, and teardown waits for the animation. Reopening
        // mid-animation flips isPDFPaneVisible back, which voids the completion.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.26
            context.allowsImplicitAnimation = true
            widthConstraint.animator().constant = 0
            if let window = view.window,
               let restoreFrame {
                window.animator().setFrame(restoreFrame, display: true)
            }
            view.superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, !self.isPDFPaneVisible else { return }
            self.pdfPaneView.isHidden = true
            self.releaseActivePDFContext()
        })
        return true
    }

    /// Layer backgrounds and PDFKit's margin color snapshot the appearance at
    /// assignment time — resolve them under the pane's effective appearance and
    /// re-run on every appearance change (settings theme toggle, system switch).
    private func applyPDFPaneAppearanceColors() {
        pdfPaneView.effectiveAppearance.performAsCurrentDrawingAppearance {
            for view in paneBackgroundLayerViews {
                view.layer?.backgroundColor = PDFPaneStyle.background.cgColor
            }
            for view in paneSeparatorLayerViews {
                view.layer?.backgroundColor = PDFPaneStyle.separator.cgColor
            }
            let resolvedSurface = NSColor(cgColor: PDFPaneStyle.surface.cgColor) ?? PDFPaneStyle.surface
            pdfPanePDFView.backgroundColor = resolvedSurface
            pdfOutlineScrollView.backgroundColor = resolvedSurface
            pdfFindSearchField.backgroundColor = resolvedSurface
        }
    }

    private func configurePDFPane() {
        pdfPaneView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneView.wantsLayer = true
        paneBackgroundLayerViews.append(pdfPaneView)
        pdfPaneView.onEffectiveAppearanceChange = { [weak self] in
            self?.applyPDFPaneAppearanceColors()
        }
        pdfPaneView.isHidden = true

        pdfPaneWidthConstraint = pdfPaneView.widthAnchor.constraint(equalToConstant: 0)
        pdfPaneWidthConstraint?.isActive = true

        let divider = NSView(frame: .zero)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        paneSeparatorLayerViews.append(divider)

        pdfPaneHeaderView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneHeaderView.wantsLayer = true
        paneBackgroundLayerViews.append(pdfPaneHeaderView)
        pdfPaneResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneTitleField.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneStatusField.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneHintIconView.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneOutlineButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneLinkButton.translatesAutoresizingMaskIntoConstraints = false
        pdfPaneCloseButton.translatesAutoresizingMaskIntoConstraints = false
        pdfFindBarView.translatesAutoresizingMaskIntoConstraints = false
        pdfFindSearchField.translatesAutoresizingMaskIntoConstraints = false
        pdfFindCounterField.translatesAutoresizingMaskIntoConstraints = false
        pdfFindPreviousButton.translatesAutoresizingMaskIntoConstraints = false
        pdfFindNextButton.translatesAutoresizingMaskIntoConstraints = false
        pdfOutlineScrollView.translatesAutoresizingMaskIntoConstraints = false
        pdfOutlineStackView.translatesAutoresizingMaskIntoConstraints = false
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

        pdfPaneOutlineButton.target = self
        pdfPaneOutlineButton.action = #selector(handlePDFOutlineToggle)
        pdfPaneOutlineButton.bezelStyle = .texturedRounded
        pdfPaneOutlineButton.controlSize = .small
        pdfPaneOutlineButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        pdfPaneOutlineButton.imagePosition = .imageOnly
        pdfPaneOutlineButton.imageScaling = .scaleProportionallyDown
        pdfPaneOutlineButton.isBordered = true
        pdfPaneOutlineButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneOutlineButton.contentTintColor = PDFPaneStyle.textMuted
        pdfPaneOutlineButton.toolTip = "Show outline"
        pdfPaneOutlineButton.setAccessibilityLabel("Toggle PDF outline")
        pdfPaneOutlineButton.setButtonType(.toggle)
        pdfPaneOutlineButton.isHidden = true
        pdfPaneOutlineButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfPaneOutlineButton.setContentHuggingPriority(.required, for: .horizontal)

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

        pdfFindBarView.wantsLayer = true
        paneBackgroundLayerViews.append(pdfFindBarView)
        pdfFindBarView.isHidden = true
        pdfFindBarView.alphaValue = 0

        pdfFindSearchField.placeholderString = "Find in document"
        pdfFindSearchField.font = NSFont.systemFont(ofSize: 13)
        pdfFindSearchField.textColor = PDFPaneStyle.text
        pdfFindSearchField.controlSize = .small
        pdfFindSearchField.isBordered = false
        pdfFindSearchField.drawsBackground = true
        pdfFindSearchField.focusRingType = .none
        pdfFindSearchField.delegate = self
        pdfFindSearchField.sendsSearchStringImmediately = true
        pdfFindSearchField.sendsWholeSearchString = false
        pdfFindSearchField.onKeyDown = { [weak self] event in
            self?.handlePDFFindKeyDown(event) ?? false
        }

        pdfFindCounterField.font = NSFont.systemFont(ofSize: 12)
        pdfFindCounterField.textColor = PDFPaneStyle.textMuted
        pdfFindCounterField.alignment = .right
        pdfFindCounterField.stringValue = ""
        pdfFindCounterField.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfFindCounterField.setContentHuggingPriority(.required, for: .horizontal)

        configureFindButton(
            pdfFindPreviousButton,
            symbolName: "chevron.up",
            action: #selector(handlePDFFindPrevious)
        )
        configureFindButton(
            pdfFindNextButton,
            symbolName: "chevron.down",
            action: #selector(handlePDFFindNext)
        )

        pdfOutlineScrollView.drawsBackground = true
        pdfOutlineScrollView.hasVerticalScroller = true
        pdfOutlineScrollView.hasHorizontalScroller = false
        pdfOutlineScrollView.borderType = .noBorder
        pdfOutlineScrollView.isHidden = true
        pdfOutlineScrollView.documentView = pdfOutlineStackView

        pdfOutlineStackView.orientation = .vertical
        pdfOutlineStackView.alignment = .leading
        pdfOutlineStackView.distribution = .gravityAreas
        pdfOutlineStackView.spacing = 0

        pdfPanePDFView.autoScales = true
        pdfPanePDFView.displayMode = .singlePageContinuous
        pdfPanePDFView.displayDirection = .vertical
        pdfPanePDFView.displaysAsBook = false
        let pageControllerSelector = NSSelectorFromString("usePageViewController:withViewOptions:")
        if pdfPanePDFView.responds(to: pageControllerSelector) {
            pdfPanePDFView.perform(pageControllerSelector, with: NSNumber(value: true), with: nil)
        }

        let headerSeparator = NSView(frame: .zero)
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.wantsLayer = true
        paneSeparatorLayerViews.append(headerSeparator)

        let findSeparator = NSView(frame: .zero)
        findSeparator.translatesAutoresizingMaskIntoConstraints = false
        findSeparator.wantsLayer = true
        paneSeparatorLayerViews.append(findSeparator)

        applyPDFPaneAppearanceColors()

        pdfPaneView.addSubview(divider)
        pdfPaneView.addSubview(pdfPaneResizeHandle)
        pdfPaneView.addSubview(pdfPaneHeaderView)
        pdfPaneView.addSubview(pdfFindBarView)
        pdfPaneView.addSubview(pdfOutlineScrollView)
        pdfPaneView.addSubview(pdfPanePDFView)
        pdfPaneHeaderView.addSubview(pdfPaneTitleField)
        pdfPaneHeaderView.addSubview(pdfPaneHintIconView)
        pdfPaneHeaderView.addSubview(pdfPaneStatusField)
        pdfPaneHeaderView.addSubview(pdfPaneOutlineButton)
        pdfPaneHeaderView.addSubview(pdfPaneLinkButton)
        pdfPaneHeaderView.addSubview(pdfPaneCloseButton)
        pdfPaneHeaderView.addSubview(headerSeparator)
        pdfFindBarView.addSubview(pdfFindSearchField)
        pdfFindBarView.addSubview(pdfFindCounterField)
        pdfFindBarView.addSubview(pdfFindPreviousButton)
        pdfFindBarView.addSubview(pdfFindNextButton)
        pdfFindBarView.addSubview(findSeparator)

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
            pdfPaneTitleField.trailingAnchor.constraint(lessThanOrEqualTo: pdfPaneOutlineButton.leadingAnchor, constant: -10),

            pdfPaneHintIconView.leadingAnchor.constraint(equalTo: pdfPaneTitleField.leadingAnchor),
            pdfPaneHintIconView.centerYAnchor.constraint(equalTo: pdfPaneStatusField.centerYAnchor),
            pdfPaneHintIconView.widthAnchor.constraint(equalToConstant: 12),
            pdfPaneHintIconView.heightAnchor.constraint(equalToConstant: 12),

            pdfPaneStatusField.topAnchor.constraint(equalTo: pdfPaneTitleField.bottomAnchor, constant: 1),
            pdfPaneStatusField.trailingAnchor.constraint(lessThanOrEqualTo: pdfPaneOutlineButton.leadingAnchor, constant: -10),
            pdfPaneStatusField.bottomAnchor.constraint(lessThanOrEqualTo: pdfPaneHeaderView.bottomAnchor, constant: -5),

            pdfPaneCloseButton.trailingAnchor.constraint(equalTo: pdfPaneHeaderView.trailingAnchor, constant: -10),
            pdfPaneCloseButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneCloseButton.widthAnchor.constraint(equalToConstant: 28),
            pdfPaneCloseButton.heightAnchor.constraint(equalToConstant: 28),

            pdfPaneLinkButton.trailingAnchor.constraint(equalTo: pdfPaneCloseButton.leadingAnchor, constant: -8),
            pdfPaneLinkButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneLinkButton.widthAnchor.constraint(equalToConstant: 28),
            pdfPaneLinkButton.heightAnchor.constraint(equalToConstant: 28),

            pdfPaneOutlineButton.trailingAnchor.constraint(equalTo: pdfPaneLinkButton.leadingAnchor, constant: -8),
            pdfPaneOutlineButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneOutlineButton.heightAnchor.constraint(equalToConstant: 28),

            headerSeparator.leadingAnchor.constraint(equalTo: pdfPaneHeaderView.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: pdfPaneHeaderView.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: pdfPaneHeaderView.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),

            pdfFindBarView.leadingAnchor.constraint(equalTo: pdfPaneView.leadingAnchor),
            pdfFindBarView.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor, constant: -1),
            pdfFindBarView.topAnchor.constraint(equalTo: pdfPaneHeaderView.bottomAnchor),

            pdfFindSearchField.leadingAnchor.constraint(equalTo: pdfFindBarView.leadingAnchor, constant: 12),
            pdfFindSearchField.centerYAnchor.constraint(equalTo: pdfFindBarView.centerYAnchor),
            pdfFindSearchField.heightAnchor.constraint(equalToConstant: 24),

            pdfFindCounterField.leadingAnchor.constraint(greaterThanOrEqualTo: pdfFindSearchField.trailingAnchor, constant: 8),
            pdfFindCounterField.trailingAnchor.constraint(equalTo: pdfFindPreviousButton.leadingAnchor, constant: -8),
            pdfFindCounterField.centerYAnchor.constraint(equalTo: pdfFindBarView.centerYAnchor),
            pdfFindCounterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            pdfFindPreviousButton.trailingAnchor.constraint(equalTo: pdfFindNextButton.leadingAnchor, constant: -4),
            pdfFindPreviousButton.centerYAnchor.constraint(equalTo: pdfFindBarView.centerYAnchor),
            pdfFindPreviousButton.widthAnchor.constraint(equalToConstant: 24),
            pdfFindPreviousButton.heightAnchor.constraint(equalToConstant: 24),

            pdfFindNextButton.trailingAnchor.constraint(equalTo: pdfFindBarView.trailingAnchor, constant: -10),
            pdfFindNextButton.centerYAnchor.constraint(equalTo: pdfFindBarView.centerYAnchor),
            pdfFindNextButton.widthAnchor.constraint(equalToConstant: 24),
            pdfFindNextButton.heightAnchor.constraint(equalToConstant: 24),

            findSeparator.leadingAnchor.constraint(equalTo: pdfFindBarView.leadingAnchor),
            findSeparator.trailingAnchor.constraint(equalTo: pdfFindBarView.trailingAnchor),
            findSeparator.bottomAnchor.constraint(equalTo: pdfFindBarView.bottomAnchor),
            findSeparator.heightAnchor.constraint(equalToConstant: 1),

            pdfOutlineScrollView.leadingAnchor.constraint(equalTo: pdfPaneView.leadingAnchor),
            pdfOutlineScrollView.topAnchor.constraint(equalTo: pdfFindBarView.bottomAnchor),
            pdfOutlineScrollView.bottomAnchor.constraint(equalTo: pdfPaneView.bottomAnchor),

            pdfOutlineStackView.leadingAnchor.constraint(equalTo: pdfOutlineScrollView.contentView.leadingAnchor),
            pdfOutlineStackView.trailingAnchor.constraint(equalTo: pdfOutlineScrollView.contentView.trailingAnchor),
            pdfOutlineStackView.topAnchor.constraint(equalTo: pdfOutlineScrollView.contentView.topAnchor),
            pdfOutlineStackView.widthAnchor.constraint(equalTo: pdfOutlineScrollView.contentView.widthAnchor),

            pdfPanePDFView.leadingAnchor.constraint(equalTo: pdfOutlineScrollView.trailingAnchor),
            pdfPanePDFView.trailingAnchor.constraint(equalTo: pdfPaneView.trailingAnchor, constant: -8),
            pdfPanePDFView.topAnchor.constraint(equalTo: pdfFindBarView.bottomAnchor),
            pdfPanePDFView.bottomAnchor.constraint(equalTo: pdfPaneView.bottomAnchor),
        ])

        pdfFindBarHeightConstraint = pdfFindBarView.heightAnchor.constraint(equalToConstant: 0)
        pdfFindBarHeightConstraint?.isActive = true
        pdfOutlineWidthConstraint = pdfOutlineScrollView.widthAnchor.constraint(equalToConstant: 0)
        pdfOutlineWidthConstraint?.isActive = true
        pdfPaneOutlineButtonWidthConstraint = pdfPaneOutlineButton.widthAnchor.constraint(equalToConstant: 0)
        pdfPaneOutlineButtonWidthConstraint?.isActive = true
        pdfFindSearchField.trailingAnchor.constraint(
            lessThanOrEqualTo: pdfFindCounterField.leadingAnchor,
            constant: -8
        ).isActive = true

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

    private func configureFindButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = PDFPaneStyle.textMuted
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configurePDFOutline(document: PDFDocument?) {
        pdfOutlineEntries = document?.outlineRoot.flatMap { flattenPDFOutline($0) } ?? []
        rebuildPDFOutlineSidebar()
        pdfPaneOutlineButton.isHidden = pdfOutlineEntries.isEmpty
        pdfPaneOutlineButtonWidthConstraint?.constant = pdfOutlineEntries.isEmpty ? 0 : 28
        if pdfOutlineEntries.isEmpty {
            setPDFOutlineVisible(false)
        }
    }

    private func flattenPDFOutline(_ root: PDFOutline, depth: Int = 0) -> [PDFOutlineSidebarEntry] {
        guard depth < 3 else { return [] }

        var entries: [PDFOutlineSidebarEntry] = []
        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index) else { continue }
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            entries.append(PDFOutlineSidebarEntry(
                title: displayTitle,
                destination: child.destination,
                depth: depth
            ))
            entries.append(contentsOf: flattenPDFOutline(child, depth: depth + 1))
        }
        return entries
    }

    private func rebuildPDFOutlineSidebar() {
        pdfOutlineStackView.arrangedSubviews.forEach { view in
            pdfOutlineStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, entry) in pdfOutlineEntries.enumerated() {
            let row = NSView(frame: .zero)
            row.translatesAutoresizingMaskIntoConstraints = false
            let button = NSButton(title: entry.title, target: self, action: #selector(handlePDFOutlineEntryClick(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 12)
            button.contentTintColor = entry.destination == nil ? PDFPaneStyle.textMuted : PDFPaneStyle.text
            button.isEnabled = entry.destination != nil
            button.lineBreakMode = .byTruncatingTail
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addSubview(button)
            pdfOutlineStackView.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: pdfOutlineStackView.widthAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10 + CGFloat(entry.depth * 14)),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }
    }

    @objc private func handlePDFOutlineToggle() {
        setPDFOutlineVisible(!isPDFOutlineVisible)
    }

    @objc private func handlePDFOutlineEntryClick(_ sender: NSButton) {
        guard sender.tag >= 0,
              sender.tag < pdfOutlineEntries.count,
              let destination = pdfOutlineEntries[sender.tag].destination else {
            return
        }

        pdfPanePDFView.go(to: destination)
    }

    private func setPDFOutlineVisible(_ visible: Bool) {
        let shouldShow = visible && !pdfOutlineEntries.isEmpty
        isPDFOutlineVisible = shouldShow
        pdfOutlineScrollView.isHidden = !shouldShow
        pdfOutlineWidthConstraint?.constant = shouldShow ? 220 : 0
        pdfPaneOutlineButton.state = shouldShow ? .on : .off
        pdfPaneOutlineButton.toolTip = shouldShow ? "Hide outline" : "Show outline"
        view.layoutSubtreeIfNeeded()
    }

    private func schedulePDFPageSave() {
        pdfPageSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveCurrentPDFPageIndex()
        }
        pdfPageSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func flushPDFPageSave() {
        pdfPageSaveWorkItem?.cancel()
        pdfPageSaveWorkItem = nil
        saveCurrentPDFPageIndex()
    }

    private func saveCurrentPDFPageIndex() {
        guard let context = activePDFContext,
              let document = pdfPanePDFView.document,
              let page = pdfPanePDFView.currentPage else {
            return
        }

        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
        onPageChanged?(context.sourceId, pageIndex)
    }

    private func showPDFPaneMessage(_ message: String) {
        pdfPaneMessageWorkItem?.cancel()
        pdfPaneTransientMessage = message
        updatePDFPaneStatus()

        let workItem = DispatchWorkItem { [weak self] in
            self?.pdfPaneTransientMessage = nil
            self?.updatePDFPaneStatus()
        }
        pdfPaneMessageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func handlePDFFindKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShift = flags.contains(.shift)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == PDFHighlightAnnotationStyle.escapeKeyCode {
            dismissPDFFindBar(clearQuery: true, restoreFocus: true)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            isShift ? selectPreviousPDFFindMatch() : selectNextPDFFindMatch()
            return true
        }

        if flags.contains(.command), characters == "g" {
            isShift ? selectPreviousPDFFindMatch() : selectNextPDFFindMatch()
            return true
        }

        return false
    }

    private func showPDFFindBar() {
        guard isPDFPaneVisible else { return }

        pdfFindBarHeightConstraint?.constant = 36
        pdfFindBarView.isHidden = false
        pdfFindBarView.alphaValue = 0
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(pdfFindSearchField)
        pdfFindSearchField.currentEditor()?.selectAll(nil)
        updatePDFFindControls()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            pdfFindBarView.animator().alphaValue = 1
        }
    }

    private func dismissPDFFindBar(clearQuery: Bool, restoreFocus: Bool) {
        pdfFindDebounceWorkItem?.cancel()

        if clearQuery {
            pdfFindSearchField.stringValue = ""
            resetPDFFindState()
        }

        let finish = { [weak self] in
            guard let self else { return }
            self.pdfFindBarHeightConstraint?.constant = 0
            self.pdfFindBarView.isHidden = true
            self.pdfFindBarView.alphaValue = 0
            self.view.layoutSubtreeIfNeeded()
            if restoreFocus {
                self.view.window?.makeFirstResponder(self.pdfPanePDFView)
            }
        }

        guard !pdfFindBarView.isHidden else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            pdfFindBarView.animator().alphaValue = 0
        } completionHandler: {
            finish()
        }
    }

    private func resetPDFFindState() {
        pdfFindDebounceWorkItem?.cancel()
        pdfFindGeneration += 1
        pdfFindMatches = []
        pdfFindCurrentIndex = nil
        pdfFindIsCapped = false
        pdfPanePDFView.highlightedSelections = []
        pdfPanePDFView.clearSelection()
        updatePDFFindControls()
    }

    private func schedulePDFFindSearch() {
        pdfFindDebounceWorkItem?.cancel()

        let query = pdfFindSearchField.stringValue
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            resetPDFFindState()
            return
        }

        guard let document = pdfPanePDFView.document else {
            resetPDFFindState()
            return
        }

        pdfFindGeneration += 1
        let generation = pdfFindGeneration
        let workItem = DispatchWorkItem { [weak self, document, query, generation] in
            guard self != nil else { return }
            let results = PDFDocumentFind.matches(in: document, query: query)

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pdfFindGeneration == generation,
                      self.pdfFindSearchField.stringValue == query else {
                    return
                }
                self.applyPDFFindResults(results)
            }
        }

        pdfFindDebounceWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.25,
            execute: workItem
        )
    }

    private func applyPDFFindResults(_ results: PDFFindResults) {
        pdfFindMatches = results.selections
        pdfFindIsCapped = results.isCapped
        pdfFindCurrentIndex = results.selections.isEmpty ? nil : 0
        pdfPanePDFView.highlightedSelections = results.selections

        if let index = pdfFindCurrentIndex {
            selectPDFFindMatch(at: index)
        } else {
            pdfPanePDFView.clearSelection()
            updatePDFFindControls()
        }
    }

    @objc private func handlePDFFindPrevious() {
        selectPreviousPDFFindMatch()
    }

    @objc private func handlePDFFindNext() {
        selectNextPDFFindMatch()
    }

    private func selectPreviousPDFFindMatch() {
        guard let next = PDFFindNavigation.previousIndex(
            currentIndex: pdfFindCurrentIndex,
            matchCount: pdfFindMatches.count
        ) else {
            return
        }
        selectPDFFindMatch(at: next)
    }

    private func selectNextPDFFindMatch() {
        guard let next = PDFFindNavigation.nextIndex(
            currentIndex: pdfFindCurrentIndex,
            matchCount: pdfFindMatches.count
        ) else {
            return
        }
        selectPDFFindMatch(at: next)
    }

    private func selectPDFFindMatch(at index: Int) {
        guard pdfFindMatches.indices.contains(index) else { return }
        let selection = pdfFindMatches[index]
        pdfFindCurrentIndex = index
        pdfPanePDFView.setCurrentSelection(selection, animate: false)

        if let page = selection.pages.first {
            let bounds = selection.bounds(for: page).standardized
            if bounds.isFiniteAndNonEmpty {
                navigate(to: bounds, on: page)
            }
        }

        updatePDFFindControls()
    }

    private func updatePDFFindControls() {
        if pdfFindSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pdfFindCounterField.stringValue = ""
        } else if let index = pdfFindCurrentIndex, !pdfFindMatches.isEmpty {
            let total = "\(pdfFindMatches.count)\(pdfFindIsCapped ? "+" : "")"
            pdfFindCounterField.stringValue = "\(index + 1) of \(total)"
        } else {
            pdfFindCounterField.stringValue = "0 of 0"
        }

        let hasMatches = !pdfFindMatches.isEmpty
        pdfFindPreviousButton.isEnabled = hasMatches
        pdfFindNextButton.isEnabled = hasMatches
        pdfFindPreviousButton.contentTintColor = hasMatches ? PDFPaneStyle.textMuted : PDFPaneStyle.textMuted.withAlphaComponent(0.45)
        pdfFindNextButton.contentTintColor = hasMatches ? PDFPaneStyle.textMuted : PDFPaneStyle.textMuted.withAlphaComponent(0.45)
    }

    private func firstResponderIsInPDFPane() -> Bool {
        guard let firstResponder = view.window?.firstResponder else {
            return false
        }

        if firstResponder === pdfFindSearchField.currentEditor() {
            return true
        }

        guard let responderView = firstResponder as? NSView else {
            return false
        }

        return responderView === pdfPaneView || responderView.isDescendant(of: pdfPaneView)
    }

    private func firstResponderIsInPDFFindBar() -> Bool {
        guard let firstResponder = view.window?.firstResponder else {
            return false
        }

        if firstResponder === pdfFindSearchField.currentEditor() {
            return true
        }

        guard let responderView = firstResponder as? NSView else {
            return false
        }

        return responderView === pdfFindBarView || responderView.isDescendant(of: pdfFindBarView)
    }

    private func maxAllowedPDFPaneWidth() -> CGFloat {
        let hostWidth = view.superview?.bounds.width ?? view.bounds.width
        return PDFPaneWidthPolicy.maxAllowedPDFPaneWidth(
            hostWidth: hostWidth,
            minimumPDFPaneWidth: minimumPDFPaneWidth,
            minimumEditorPaneWidth: minimumEditorPaneWidth
        )
    }

    private func clampPDFPaneWidth(_ proposed: CGFloat) -> CGFloat {
        let hostWidth = view.superview?.bounds.width ?? view.bounds.width
        return PDFPaneWidthPolicy.clampPDFPaneWidth(
            proposed,
            hostWidth: hostWidth,
            minimumPDFPaneWidth: minimumPDFPaneWidth,
            minimumEditorPaneWidth: minimumEditorPaneWidth
        )
    }

    private func setPDFPaneHeader(displayName: String?) {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            pdfPaneTitleField.stringValue = "PDF Source"
            pdfPaneTitleField.toolTip = nil
        } else {
            pdfPaneTitleField.stringValue = SourceShortTitle.derive(displayName: trimmed)
            pdfPaneTitleField.toolTip = trimmed
        }
    }

    private func releaseActivePDFContext() {
        exitAnchorPickMode(notifyCancelled: false)
        flushPDFPageSave()
        pdfPageSaveWorkItem?.cancel()
        pdfPaneMessageWorkItem?.cancel()
        pdfPaneTransientMessage = nil
        resetPDFFindState()
        if let current = activePDFContext {
            current.fileURL.stopAccessingSecurityScopedResource()
        }
        activePDFContext = nil
        pdfPanePDFView.document = nil
        configurePDFOutline(document: nil)
        setPDFPaneHeader(displayName: nil)
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
        schedulePDFPageSave()
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
            showPDFPaneMessage("Open a PDF before linking.")
            return
        }
        guard let selection = pdfPanePDFView.currentSelection else {
            showPDFPaneMessage("Nothing is selected to link.")
            return
        }

        let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !quote.isEmpty else {
            showPDFPaneMessage("Nothing is selected to link.")
            return
        }

        let rects = highlightRects(for: selection)
        guard let firstRect = rects.first else {
            showPDFPaneMessage("That selection cannot be linked.")
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
            let fallbackPage = PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: pageNumber)
            if let page = navigate(toPageNumber: fallbackPage),
               PDFCitationFallbackAffordance.shouldShow(chunkPresent: true, matchFound: false) {
                showCitationPageFallbackAffordance(on: page)
            }
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

    @discardableResult
    private func navigate(toPageNumber pageNumber: Int?) -> PDFPage? {
        guard let document = pdfPanePDFView.document,
              document.pageCount > 0 else {
            return nil
        }

        let clampedPage = max(1, min(pageNumber ?? 1, document.pageCount))
        guard let page = document.page(at: clampedPage - 1) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
        pdfPanePDFView.go(to: destination)
        return page
    }

    @discardableResult
    private func navigate(toPageIndex pageIndex: Int) -> PDFPage? {
        guard let document = pdfPanePDFView.document,
              document.pageCount > 0 else {
            return nil
        }

        let clampedPageIndex = max(0, min(pageIndex, document.pageCount - 1))
        guard let page = document.page(at: clampedPageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
        pdfPanePDFView.go(to: destination)
        return page
    }

    private func showCitationPageFallbackAffordance(on page: PDFPage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.pdfPanePDFView.layoutSubtreeIfNeeded()
            let pageRect = self.pdfPanePDFView.convert(page.bounds(for: .cropBox), from: page)
            let visiblePageRect = pageRect.intersection(self.pdfPanePDFView.bounds)
            guard visiblePageRect.isFiniteAndNonEmpty else { return }

            let flash = self.makeCitationPageFallbackFlash(visiblePageRect: visiblePageRect)
            self.pdfPanePDFView.addSubview(flash)
            self.fadeTransientCitationFallbackViews([flash])
        }
    }

    private func makeCitationPageFallbackFlash(visiblePageRect: CGRect) -> NSView {
        let flash = NSView(frame: visiblePageRect)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = PDFHighlightAnnotationStyle.pulseColor.withAlphaComponent(0.38).cgColor
        flash.alphaValue = 0
        return flash
    }

    private func fadeTransientCitationFallbackViews(_ views: [NSView]) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            views.forEach { $0.animator().alphaValue = 1 }
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.0
                views.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                views.forEach { $0.removeFromSuperview() }
            }
        }
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
            showPDFPaneMessage("Pick a spot inside the PDF.")
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
            setPDFPaneHeader(displayName: context.sourceName)
        } else {
            setPDFPaneHeader(displayName: nil)
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
        if let message = pdfPaneTransientMessage {
            pdfPaneHintIconView.isHidden = true
            pdfPaneStatusLeadingConstraint?.isActive = true
            pdfPaneStatusHintLeadingConstraint?.isActive = false
            pdfPaneStatusField.stringValue = [pageText, message].filter { !$0.isEmpty }.joined(separator: " · ")
            return
        }

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

extension PDFReaderPaneController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField,
              searchField === pdfFindSearchField else { return }
        schedulePDFFindSearch()
    }
}
