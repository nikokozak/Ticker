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

@MainActor
final class PDFReaderWindowController: NSWindowController, NSWindowDelegate {
    private let streamId: UUID
    private let sourceId: UUID
    private let sourceName: String
    private let sourceURL: URL
    private let onCreateLink: (PDFHighlightLinkPayload) -> Void
    private let onClose: () -> Void

    private let pdfView = PDFView(frame: .zero)
    private let linkSelectionButton = NSButton(title: "Link Selection", target: nil, action: nil)

    init(
        streamId: UUID,
        sourceId: UUID,
        sourceName: String,
        sourceURL: URL,
        onCreateLink: @escaping (PDFHighlightLinkPayload) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.streamId = streamId
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.onCreateLink = onCreateLink
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = sourceName
        window.minSize = NSSize(width: 640, height: 420)

        super.init(window: window)
        window.delegate = self

        configureUI()
        loadDocument()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClose()
    }

    @objc private func handleSelectionChange() {
        let selectedText = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        linkSelectionButton.isEnabled = !selectedText.isEmpty
    }

    @objc private func handleClose() {
        window?.close()
    }

    @objc private func handleLinkSelection() {
        guard let selection = pdfView.currentSelection else {
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
            pdfView.document?.index(for: page).map { $0 + 1 }
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

        let payload = PDFHighlightLinkPayload(
            streamId: streamId,
            sourceId: sourceId,
            sourceName: sourceName,
            highlightId: highlightId,
            page: pageNumber,
            quote: quote
        )
        onCreateLink(payload)
    }

    private func configureUI() {
        guard let window else { return }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: sourceName)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        linkSelectionButton.target = self
        linkSelectionButton.action = #selector(handleLinkSelection)
        linkSelectionButton.bezelStyle = .rounded
        linkSelectionButton.controlSize = .small
        linkSelectionButton.isEnabled = false

        let closeButton = NSButton(title: "Close", target: self, action: #selector(handleClose))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small

        controls.addArrangedSubview(linkSelectionButton)
        controls.addArrangedSubview(closeButton)

        header.addSubview(titleLabel)
        header.addSubview(controls)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        pdfView.usePageViewController(true, withViewOptions: nil)

        root.addSubview(header)
        root.addSubview(pdfView)

        let controller = NSViewController()
        controller.view = root
        window.contentViewController = controller

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -10),

            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectionChange),
            name: Notification.Name.PDFViewSelectionChanged,
            object: pdfView
        )
    }

    private func loadDocument() {
        guard let document = PDFDocument(url: sourceURL) else {
            NSSound.beep()
            return
        }
        pdfView.document = document
    }
}
