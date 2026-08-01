import AppKit
import PDFKit

struct PDFHighlightLinkPayload {
    let streamId: UUID
    let sourceName: String
    let highlight: PDFHighlightRecord
}

struct PDFHighlightRevealPayload {
    let streamId: UUID
    let sourceId: UUID
    let highlightId: UUID
}

enum PDFSectionAction: String {
    case ask
    case summarize
}

struct PDFSectionActionPayload {
    let action: PDFSectionAction
    let descriptor: PDFSectionDescriptor
    let page: Int
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
}

private enum PDFHighlightAnnotationStyle {
    static let color = NSColor.systemYellow.withAlphaComponent(0.32)
    static let pulseColor = NSColor.systemYellow.withAlphaComponent(0.62)
    static let markerColor = NativePalette.accent.withAlphaComponent(0.38)
    static let markerPulseColor = NativePalette.accent.withAlphaComponent(0.74)
    static let markerSize: CGFloat = 14
    static let escapeKeyCode: UInt16 = 53
}

enum PDFHighlightAnnotationTag {
    static let prefix = "ticker-pdf-highlight:"

    static func contents(for highlightId: UUID) -> String {
        "\(prefix)\(highlightId.uuidString)"
    }

    static func highlightId(from contents: String?) -> UUID? {
        guard let contents, contents.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(contents.dropFirst(prefix.count)))
    }
}

struct PDFHighlightClickTracker {
    static let slop: CGFloat = 4

    let mouseDownLocation: CGPoint
    private(set) var exceededSlop = false

    mutating func observe(_ location: CGPoint) {
        let dx = location.x - mouseDownLocation.x
        let dy = location.y - mouseDownLocation.y
        if (dx * dx) + (dy * dy) > Self.slop * Self.slop {
            exceededSlop = true
        }
    }
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

    /// Accordion semantics — the pane lives on the LEFT of the editor. The
    /// pane opens at its classic size (half the screen, capped by what the
    /// screen and the editor's minimum allow), the window grows leftward by
    /// exactly the pane width so the editor keeps its size, and the right
    /// edge (the editor) stays put unless the left screen edge would clip the
    /// pane — then the window slides right, translating but never resizing
    /// the editor. Height and vertical position are never touched.
    static func calculate(
        currentFrame: CGRect,
        visibleFrame: CGRect,
        isNativeFullscreen: Bool
    ) -> PDFPaneOpeningLayout {
        if isNativeFullscreen || currentFrame.width >= visibleFrame.width {
            return PDFPaneOpeningLayout(
                targetWindowFrame: currentFrame,
                paneWidth: floor(currentFrame.width * 0.5),
                shouldResizeWindow: false
            )
        }

        let desiredPaneWidth = floor(visibleFrame.width * 0.5)
        let growth = max(0, visibleFrame.width - currentFrame.width)
        let rawPaneWidth = max(min(desiredPaneWidth, growth), PDFPaneWidthPolicy.minimumPDFPaneWidth)
        let targetWidth = min(currentFrame.width + rawPaneWidth, visibleFrame.width)
        let paneWidth = PDFPaneWidthPolicy.clampPDFPaneWidth(rawPaneWidth, hostWidth: targetWidth)

        let idealX = currentFrame.maxX - targetWidth // right edge fixed
        let x = min(max(idealX, visibleFrame.minX), visibleFrame.maxX - targetWidth)
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
    var onLinkSelection: (@MainActor (PDFHighlightLinkPayload) -> Bool)?
    var onDiscussSelection: (@MainActor (PDFHighlightLinkPayload) -> Bool)?
    var onAnchorPlaced: (@MainActor (PDFHighlightLinkPayload) -> Bool)?
    var onAnchorPickCancelled: ((UUID) -> Void)?
    var onSectionAction: (@MainActor (PDFSectionActionPayload) -> Void)?
    var onRevealHighlightInStream: (@MainActor (PDFHighlightRevealPayload) -> Void)?
    var onDeleteHighlight: (@MainActor (PDFHighlightRevealPayload) -> Bool)?
    var onPageChanged: ((UUID, Int) -> Void)?
    var onSelectionChanged: (@MainActor (UUID, UUID, String, PDFHighlightRecord?) -> Void)?
    var highlightsProvider: ((UUID) -> [PDFHighlightRecord])?
    var sectionProvider: ((UUID, UUID, Int) throws -> PDFSectionDescriptor)?
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
    private let pdfPaneDiscussButton = NSButton(title: "", target: nil, action: nil)
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
    /// True while the pane's open expanded the window, so close knows to
    /// give that width back (computed from the current frame, never saved).
    private var didExpandWindowForPDFPane = false
    private var suspendedFrameAutosaveName: String?
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
    private var activePDFContext: (streamId: UUID, sourceId: UUID, sourceName: String, fileURL: URL)?
    private var isAnchorPickMode = false
    private var anchorPickMouseMonitor: Any?
    private var anchorPickKeyMonitor: Any?
    private var anchorPickCursorMonitor: Any?
    private var pdfHighlightActivationMonitor: Any?
    private var pdfHighlightClickTracker: PDFHighlightClickTracker?
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
        if let pdfHighlightActivationMonitor {
            NSEvent.removeMonitor(pdfHighlightActivationMonitor)
        }
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
        setPDFSelectionActionsEnabled(false)
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

    func removeHighlight(id highlightId: UUID, streamId: UUID) {
        guard activePDFContext?.streamId == streamId else { return }
        for annotation in taggedAnnotations(highlightId: highlightId.uuidString) {
            annotation.page?.removeAnnotation(annotation)
        }
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
        setPDFSelectionActionsEnabled(false)
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

    @discardableResult
    /// No animation, by design. NSWindow frame animation runs on its own
    /// clock and cannot be synchronized with Auto Layout, so every animated
    /// variant visibly stretched the editor. Instead the window frame and the
    /// pane width change in the SAME layout pass: one paint, the pane is
    /// simply there (or gone), and the editor never moves or resizes.
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

            guard paneWidth >= minimumPDFPaneWidth else { return false }

            widthConstraint.constant = paneWidth
            pdfPaneView.isHidden = false
            isPDFPaneVisible = true
            didExpandWindowForPDFPane = false
            if shouldResizeWindow,
               let window = view.window,
               let targetWindowFrame {
                suspendFrameAutosave(for: window)
                window.setFrame(targetWindowFrame, display: false)
                didExpandWindowForPDFPane = true
            }
            view.superview?.layoutSubtreeIfNeeded()
            return true
        }

        guard isPDFPaneVisible else {
            if let window = view.window {
                resumeFrameAutosave(for: window)
            }
            exitAnchorPickMode(notifyCancelled: true)
            releaseActivePDFContext()
            return true
        }

        exitAnchorPickMode(notifyCancelled: true)
        dismissPDFFindBar(clearQuery: true, restoreFocus: false)

        // Inverse of the open, computed from the CURRENT frame — never from a
        // saved one, which goes stale the moment the user resizes anything:
        // the left edge moves right by the pane's width and the editor keeps
        // its exact on-screen size and position.
        let paneWidth = pdfPaneView.frame.width
        widthConstraint.constant = 0
        pdfPaneView.isHidden = true
        isPDFPaneVisible = false
        if didExpandWindowForPDFPane,
           let window = view.window,
           !window.styleMask.contains(.fullScreen),
           paneWidth > 0 {
            var frame = window.frame
            frame.origin.x += paneWidth
            frame.size.width -= paneWidth
            window.setFrame(frame, display: false)
        }
        if let window = view.window {
            resumeFrameAutosave(for: window)
        }
        didExpandWindowForPDFPane = false
        view.superview?.layoutSubtreeIfNeeded()
        releaseActivePDFContext()
        return true
    }

    private func suspendFrameAutosave(for window: NSWindow) {
        guard suspendedFrameAutosaveName == nil, !window.frameAutosaveName.isEmpty else { return }
        suspendedFrameAutosaveName = window.frameAutosaveName
        _ = window.setFrameAutosaveName("")
    }

    private func resumeFrameAutosave(for window: NSWindow) {
        guard let name = suspendedFrameAutosaveName else { return }
        _ = window.setFrameAutosaveName(name)
        if !window.styleMask.contains(.fullScreen) {
            window.saveFrame(usingName: name)
        }
        suspendedFrameAutosaveName = nil
    }

    /// Layer backgrounds and PDFKit's margin color snapshot the appearance at
    /// assignment time — resolve them under the pane's effective appearance and
    /// re-run on every appearance change (settings theme toggle, system switch).
    private func applyPDFPaneAppearanceColors() {
        pdfPaneView.effectiveAppearance.performAsCurrentDrawingAppearance {
            for view in paneBackgroundLayerViews {
                view.layer?.backgroundColor = NativePalette.background.cgColor
            }
            for view in paneSeparatorLayerViews {
                view.layer?.backgroundColor = NativePalette.separator.cgColor
            }
            let resolvedSurface = NSColor(cgColor: NativePalette.surface.cgColor) ?? NativePalette.surface
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
        pdfPaneDiscussButton.translatesAutoresizingMaskIntoConstraints = false
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
        pdfPaneTitleField.textColor = NativePalette.text
        pdfPaneTitleField.lineBreakMode = .byTruncatingMiddle
        pdfPaneTitleField.maximumNumberOfLines = 1
        pdfPaneTitleField.usesSingleLineMode = true
        pdfPaneTitleField.stringValue = "PDF Source"
        pdfPaneTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pdfPaneTitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pdfPaneStatusField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        pdfPaneStatusField.textColor = NativePalette.textMuted
        pdfPaneStatusField.lineBreakMode = .byTruncatingTail
        pdfPaneStatusField.maximumNumberOfLines = 1
        pdfPaneStatusField.usesSingleLineMode = true
        pdfPaneStatusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pdfPaneStatusField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pdfPaneHintIconView.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        pdfPaneHintIconView.imageScaling = .scaleProportionallyDown
        pdfPaneHintIconView.contentTintColor = NativePalette.accent
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
        pdfPaneOutlineButton.contentTintColor = NativePalette.textMuted
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
        pdfPaneLinkButton.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        pdfPaneLinkButton.imagePosition = .imageOnly
        pdfPaneLinkButton.imageScaling = .scaleProportionallyDown
        pdfPaneLinkButton.isBordered = true
        pdfPaneLinkButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneLinkButton.toolTip = "Add selected quote to stream"
        pdfPaneLinkButton.setAccessibilityLabel("Add selected quote to stream")
        pdfPaneLinkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfPaneLinkButton.setContentHuggingPriority(.required, for: .horizontal)

        pdfPaneDiscussButton.target = self
        pdfPaneDiscussButton.action = #selector(handlePDFPaneDiscussSelection)
        pdfPaneDiscussButton.bezelStyle = .texturedRounded
        pdfPaneDiscussButton.controlSize = .small
        pdfPaneDiscussButton.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        pdfPaneDiscussButton.imagePosition = .imageOnly
        pdfPaneDiscussButton.imageScaling = .scaleProportionallyDown
        pdfPaneDiscussButton.isBordered = true
        pdfPaneDiscussButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneDiscussButton.toolTip = "Discuss selected PDF text"
        pdfPaneDiscussButton.setAccessibilityLabel("Discuss selected PDF text")
        pdfPaneDiscussButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pdfPaneDiscussButton.setContentHuggingPriority(.required, for: .horizontal)
        setPDFSelectionActionsEnabled(false)

        pdfPaneCloseButton.target = self
        pdfPaneCloseButton.action = #selector(handlePDFPaneClose)
        pdfPaneCloseButton.bezelStyle = .texturedRounded
        pdfPaneCloseButton.controlSize = .small
        pdfPaneCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        pdfPaneCloseButton.imagePosition = .imageOnly
        pdfPaneCloseButton.imageScaling = .scaleProportionallyDown
        pdfPaneCloseButton.isBordered = true
        pdfPaneCloseButton.showsBorderOnlyWhileMouseInside = true
        pdfPaneCloseButton.contentTintColor = NativePalette.textMuted
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
        pdfFindSearchField.textColor = NativePalette.text
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
        pdfFindCounterField.textColor = NativePalette.textMuted
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
        installPDFHighlightActivationMonitor()
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
        pdfPaneHeaderView.addSubview(pdfPaneDiscussButton)
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

            pdfPaneDiscussButton.trailingAnchor.constraint(equalTo: pdfPaneLinkButton.leadingAnchor, constant: -8),
            pdfPaneDiscussButton.centerYAnchor.constraint(equalTo: pdfPaneHeaderView.centerYAnchor),
            pdfPaneDiscussButton.widthAnchor.constraint(equalToConstant: 28),
            pdfPaneDiscussButton.heightAnchor.constraint(equalToConstant: 28),

            pdfPaneOutlineButton.trailingAnchor.constraint(equalTo: pdfPaneDiscussButton.leadingAnchor, constant: -8),
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
        button.contentTintColor = NativePalette.textMuted
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
            button.contentTintColor = entry.destination == nil ? NativePalette.textMuted : NativePalette.text
            button.isEnabled = entry.destination != nil
            button.lineBreakMode = .byTruncatingTail
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if entry.destination != nil {
                button.toolTip = "Open section. Control-click for AI actions."
                let menu = NSMenu()
                let ask = NSMenuItem(
                    title: "Ask about “\(entry.title)”…",
                    action: #selector(handlePDFOutlineSectionAsk(_:)),
                    keyEquivalent: ""
                )
                ask.target = self
                ask.tag = index
                menu.addItem(ask)
                let summarize = NSMenuItem(
                    title: "Summarize “\(entry.title)”",
                    action: #selector(handlePDFOutlineSectionSummarize(_:)),
                    keyEquivalent: ""
                )
                summarize.target = self
                summarize.tag = index
                menu.addItem(summarize)
                button.menu = menu
            }
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

    @objc private func handlePDFOutlineSectionAsk(_ sender: NSMenuItem) {
        sendPDFOutlineSectionAction(.ask, entryIndex: sender.tag)
    }

    @objc private func handlePDFOutlineSectionSummarize(_ sender: NSMenuItem) {
        sendPDFOutlineSectionAction(.summarize, entryIndex: sender.tag)
    }

    private func sendPDFOutlineSectionAction(_ action: PDFSectionAction, entryIndex: Int) {
        guard let context = activePDFContext,
              let document = pdfPanePDFView.document,
              pdfOutlineEntries.indices.contains(entryIndex),
              let destinationPage = pdfOutlineEntries[entryIndex].destination?.page,
              let sectionProvider else {
            showPDFPaneMessage("This section is not available.")
            return
        }

        let pageIndex = document.index(for: destinationPage)
        guard pageIndex >= 0 else {
            showPDFPaneMessage("This section is not available.")
            return
        }

        let page = pageIndex + 1
        do {
            let descriptor = try sectionProvider(context.streamId, context.sourceId, page)
            onSectionAction?(PDFSectionActionPayload(
                action: action,
                descriptor: descriptor,
                page: page
            ))
        } catch {
            showPDFPaneMessage(error.localizedDescription)
        }
    }

    private func setPDFOutlineVisible(_ visible: Bool) {
        let shouldShow = visible && !pdfOutlineEntries.isEmpty
        isPDFOutlineVisible = shouldShow
        pdfOutlineScrollView.isHidden = !shouldShow
        pdfOutlineWidthConstraint?.constant = shouldShow ? 220 : 0
        pdfPaneOutlineButton.state = shouldShow ? .on : .off
        pdfPaneOutlineButton.showsBorderOnlyWhileMouseInside = !shouldShow
        pdfPaneOutlineButton.contentTintColor = shouldShow ? NativePalette.accent : NativePalette.textMuted
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
        pdfFindPreviousButton.contentTintColor = hasMatches ? NativePalette.textMuted : NativePalette.textMuted.withAlphaComponent(0.45)
        pdfFindNextButton.contentTintColor = hasMatches ? NativePalette.textMuted : NativePalette.textMuted.withAlphaComponent(0.45)
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
        setPDFSelectionActionsEnabled(false)
        updatePDFPaneStatus()
    }

    @objc private func handlePDFPaneClose() {
        setVisible(false)
        onClose?()
    }

    @objc private func handlePDFPaneSelectionChanged() {
        guard !isAnchorPickMode else {
            setPDFSelectionActionsEnabled(false)
            notifySelectionChanged(nil)
            return
        }
        let payload = currentSelectionPayload()
        setPDFSelectionActionsEnabled(payload != nil)
        notifySelectionChanged(payload?.highlight)
    }

    @objc private func handlePDFPanePageChanged() {
        updatePDFPaneStatus()
        schedulePDFPageSave()
    }

    private func installPDFHighlightActivationMonitor() {
        guard pdfHighlightActivationMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        pdfHighlightActivationMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePDFHighlightActivationEvent(event) ?? event
        }
    }

    private func handlePDFHighlightActivationEvent(_ event: NSEvent) -> NSEvent? {
        let pointInPDFView = pdfPanePDFView.convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            pdfHighlightClickTracker = nil
            guard !isAnchorPickMode,
                  event.clickCount == 1,
                  event.window === view.window,
                  pdfPanePDFView.bounds.contains(pointInPDFView) else {
                return event
            }
            pdfHighlightClickTracker = PDFHighlightClickTracker(mouseDownLocation: event.locationInWindow)

        case .leftMouseDragged:
            pdfHighlightClickTracker?.observe(event.locationInWindow)

        case .leftMouseUp:
            guard var tracker = pdfHighlightClickTracker else { return event }
            pdfHighlightClickTracker = nil
            tracker.observe(event.locationInWindow)
            guard !tracker.exceededSlop,
                  !isAnchorPickMode,
                  event.window === view.window,
                  pdfPanePDFView.bounds.contains(pointInPDFView) else {
                return event
            }
            revealSavedHighlight(at: pointInPDFView)

        case .rightMouseDown:
            guard !isAnchorPickMode,
                  event.window === view.window,
                  pdfPanePDFView.bounds.contains(pointInPDFView),
                  showPDFHighlightContextMenu(at: pointInPDFView) else {
                return event
            }
            return nil

        default:
            break
        }

        return event
    }

    private func showPDFHighlightContextMenu(at pointInPDFView: CGPoint) -> Bool {
        guard let page = pdfPanePDFView.page(for: pointInPDFView, nearest: false) else { return false }
        let pointOnPage = pdfPanePDFView.convert(pointInPDFView, to: page)
        guard let annotation = page.annotation(at: pointOnPage),
              let highlightId = PDFHighlightAnnotationTag.highlightId(from: annotation.contents) else {
            return false
        }

        let menu = NSMenu()
        let remove = NSMenuItem(
            title: "Remove PDF link",
            action: #selector(handlePDFHighlightDelete(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.representedObject = highlightId.uuidString
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: pointInPDFView, in: pdfPanePDFView)
        return true
    }

    @objc private func handlePDFHighlightDelete(_ sender: NSMenuItem) {
        guard let context = activePDFContext,
              let value = sender.representedObject as? String,
              let highlightId = UUID(uuidString: value),
              onDeleteHighlight?(PDFHighlightRevealPayload(
                streamId: context.streamId,
                sourceId: context.sourceId,
                highlightId: highlightId
              )) == true else {
            return
        }

        showPDFPaneMessage("PDF link removed.")
    }

    private func revealSavedHighlight(at pointInPDFView: CGPoint) {
        guard let context = activePDFContext,
              let page = pdfPanePDFView.page(for: pointInPDFView, nearest: false) else {
            return
        }
        let pointOnPage = pdfPanePDFView.convert(pointInPDFView, to: page)
        guard let annotation = page.annotation(at: pointOnPage),
              let highlightId = PDFHighlightAnnotationTag.highlightId(from: annotation.contents) else {
            return
        }

        onRevealHighlightInStream?(PDFHighlightRevealPayload(
            streamId: context.streamId,
            sourceId: context.sourceId,
            highlightId: highlightId
        ))
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
        handlePDFPaneSelection(
            missingPDFMessage: "Open a PDF before linking.",
            missingSelectionMessage: "Nothing is selected to link.",
            invalidSelectionMessage: "That selection cannot be linked.",
            action: onLinkSelection
        )
    }

    @objc private func handlePDFPaneDiscussSelection() {
        handlePDFPaneSelection(
            missingPDFMessage: "Open a PDF before starting a conversation.",
            missingSelectionMessage: "Nothing is selected to discuss.",
            invalidSelectionMessage: "That selection cannot start a conversation.",
            action: onDiscussSelection
        )
    }

    private func handlePDFPaneSelection(
        missingPDFMessage: String,
        missingSelectionMessage: String,
        invalidSelectionMessage: String,
        action: (@MainActor (PDFHighlightLinkPayload) -> Bool)?
    ) {
        exitAnchorPickMode(notifyCancelled: true)

        guard activePDFContext != nil else {
            showPDFPaneMessage(missingPDFMessage)
            return
        }
        guard pdfPanePDFView.currentSelection != nil else {
            showPDFPaneMessage(missingSelectionMessage)
            return
        }
        guard let payload = currentSelectionPayload() else {
            showPDFPaneMessage(invalidSelectionMessage)
            return
        }
        guard action?(payload) == true else { return }

        applyHighlight(payload.highlight)
        pdfPanePDFView.clearSelection()
    }

    private func currentSelectionPayload() -> PDFHighlightLinkPayload? {
        guard let context = activePDFContext,
              let selection = pdfPanePDFView.currentSelection else { return nil }
        let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rects = highlightRects(for: selection)
        guard !quote.isEmpty, let firstRect = rects.first else { return nil }
        return PDFHighlightLinkPayload(
            streamId: context.streamId,
            sourceName: context.sourceName,
            highlight: PDFHighlightRecord(
                id: UUID(),
                sourceId: context.sourceId,
                page: firstRect.page,
                rects: rects,
                quote: quote,
                createdAt: Date()
            )
        )
    }

    private func notifySelectionChanged(_ highlight: PDFHighlightRecord?) {
        guard let context = activePDFContext else { return }
        onSelectionChanged?(context.streamId, context.sourceId, context.sourceName, highlight)
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
            annotation.contents = PDFHighlightAnnotationTag.contents(for: highlight.id)
            page.addAnnotation(annotation)
        }
    }

    private func taggedAnnotations(highlightId: String) -> [PDFAnnotation] {
        guard let document = pdfPanePDFView.document else { return [] }
        let tag = "\(PDFHighlightAnnotationTag.prefix)\(highlightId)"
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

        let payload = PDFHighlightLinkPayload(
            streamId: context.streamId,
            sourceName: context.sourceName,
            highlight: highlight
        )
        let didSave = onAnchorPlaced?(payload) == true
        exitAnchorPickMode(notifyCancelled: !didSave)
        if didSave {
            applyHighlight(highlight)
        }
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
        pdfPaneTitleField.textColor = NativePalette.text
        updatePDFPaneStatus()
        handlePDFPaneSelectionChanged()

        if notifyCancelled, let streamId {
            onAnchorPickCancelled?(streamId)
        }
    }

    private func setPDFSelectionActionsEnabled(_ enabled: Bool) {
        pdfPaneDiscussButton.isEnabled = enabled
        pdfPaneDiscussButton.contentTintColor = enabled ? NativePalette.accent : NativePalette.textMuted
        pdfPaneLinkButton.isEnabled = enabled
        pdfPaneLinkButton.contentTintColor = enabled ? NativePalette.accent : NativePalette.textMuted
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
        let hintText = "Click a spot to anchor · Esc to cancel"

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
