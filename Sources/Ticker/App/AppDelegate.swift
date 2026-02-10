import AppKit
import SwiftUI
import WebKit
import ApplicationServices
import PDFKit
import Sparkle
import UniformTypeIdentifiers

// Notification for appearance changes
extension Notification.Name {
    static let appearanceDidChange = Notification.Name("appearanceDidChange")
}

// Manual entry point for proper app initialization
@main
struct TickerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, TickerNextEditorTextViewActionHandling {
    private var mainWindow: NSWindow?
    private var webViewManager: WebViewManager?
    private var onboardingWindow: NSWindow?
    private var didCompleteStartup = false
    private let libraryService = LibraryService.shared
    private var tickerNextEditorWindow: NSWindow?
    private var tickerNextEditorTextView: NSTextView?
    private var tickerNextCurrentNote: TickerMarkdownNote?
    private let tickerNextSelectionAIService = TickerNextSelectionAIService()
    private let tickerNextDocMetadataStore = TickerNextDocMetadataStore()
    private var tickerNextAuthorshipSpans: [TickerNextAuthorshipSpan] = []
    private var tickerNextPreviousEditorBody = ""
    private var tickerNextPendingAIInsertion: (range: NSRange, source: String)?
    private var tickerNextSuppressTextDidChange = false
    private var tickerNextAIRequestInFlight = false
    private var tickerNextPDFWindow: NSWindow?
    private var tickerNextPDFView: PDFView?
    private var tickerNextCurrentPDFID: UUID?

    // Menu bar (status item)
    private var statusItem: NSStatusItem?

    // Quick Panel services
    private var hotkeyService: HotkeyService?
    private var quickPanelManager: QuickPanelManager?

    // Sparkle updater (lives for app lifetime)
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenuBar()
        setupAppearanceObserver()
        setupTickerNextObservers()

        // Alpha: proxy-only onboarding (no vendor API keys).
        if SettingsService.shared.needsOnboarding {
            showOnboarding()
        } else {
            completeStartup()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Complete startup after onboarding (or skip if not needed)
    private func completeStartup() {
        guard !didCompleteStartup else { return }
        didCompleteStartup = true
        setupMainWindow()
        setupQuickPanel()
        bootstrapTickerNextLibraryIfConfigured()
        requestAccessibilityPermissionIfNeeded()
        // Apply initial appearance after Quick Panel is set up
        Task { @MainActor in
            self.applyAppearance()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            // Onboarding complete callback
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.completeStartup()
        }

        let hostingView = NSHostingView(rootView: onboardingView)

        onboardingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        onboardingWindow?.title = "Welcome to Ticker"
        onboardingWindow?.contentView = hostingView
        onboardingWindow?.center()
        onboardingWindow?.isReleasedWhenClosed = false
        onboardingWindow?.delegate = self
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupAppearanceObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: .appearanceDidChange,
            object: nil
        )
    }

    @objc private func handleAppearanceChange() {
        Task { @MainActor in
            self.applyAppearance()
        }
    }

    @MainActor
    private func applyAppearance() {
        let appearance = SettingsService.shared.nsAppearance
        mainWindow?.appearance = appearance
        quickPanelManager?.updateAppearance(appearance)
    }

    /// Request accessibility permission early so it's ready when Quick Panel is first used
    private func requestAccessibilityPermissionIfNeeded() {
        // Alpha: avoid prompting on app launch. The onboarding flow (and in-context feature usage)
        // is responsible for presenting the permission prompt.
        if !AXIsProcessTrusted() {
            DebugLog.log("[Ticker] Accessibility permission not yet granted")
        }
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Ticker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        // Sparkle "Check for Updates..." menu item
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)

        if SettingsService.tickerNextMode {
            appMenu.addItem(NSMenuItem.separator())
            let openEditorItem = NSMenuItem(
                title: "Open Ticker Next Editor",
                action: #selector(openTickerNextEditor),
                keyEquivalent: "0"
            )
            openEditorItem.target = self
            appMenu.addItem(openEditorItem)

            let newNoteItem = NSMenuItem(
                title: "New Note",
                action: #selector(createTickerNextNote),
                keyEquivalent: "n"
            )
            newNoteItem.target = self
            appMenu.addItem(newNoteItem)

            let openNoteItem = NSMenuItem(
                title: "Open Note...",
                action: #selector(openTickerNextNote),
                keyEquivalent: "o"
            )
            openNoteItem.target = self
            appMenu.addItem(openNoteItem)

            let importPDFItem = NSMenuItem(
                title: "Import PDF...",
                action: #selector(importTickerNextPDF),
                keyEquivalent: "i"
            )
            importPDFItem.target = self
            appMenu.addItem(importPDFItem)

            let showLinkedPDFItem = NSMenuItem(
                title: "Show Linked PDF",
                action: #selector(showTickerNextLinkedPDF),
                keyEquivalent: ""
            )
            showLinkedPDFItem.target = self
            appMenu.addItem(showLinkedPDFItem)

            let linkPDFSelectionItem = NSMenuItem(
                title: "Link PDF Selection to Note",
                action: #selector(linkTickerNextPDFSelectionToNote),
                keyEquivalent: ""
            )
            linkPDFSelectionItem.target = self
            appMenu.addItem(linkPDFSelectionItem)

            let openHighlightLinkItem = NSMenuItem(
                title: "Open Highlight Link at Cursor",
                action: #selector(openTickerNextHighlightLinkAtCursor),
                keyEquivalent: "j"
            )
            openHighlightLinkItem.target = self
            openHighlightLinkItem.keyEquivalentModifierMask = [.command, .shift]
            appMenu.addItem(openHighlightLinkItem)

            let saveNoteItem = NSMenuItem(
                title: "Save Note",
                action: #selector(saveTickerNextNote),
                keyEquivalent: "s"
            )
            saveNoteItem.target = self
            appMenu.addItem(saveNoteItem)

            let setLibraryFolderItem = NSMenuItem(
                title: "Set Library Folder...",
                action: #selector(selectLibraryFolder),
                keyEquivalent: ""
            )
            setLibraryFolderItem.target = self
            appMenu.addItem(setLibraryFolderItem)
        }

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Ticker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (required for copy/paste to work)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Cmd+Tab activates the app but does not trigger `applicationShouldHandleReopen`.
        // If the main window is currently hidden (common after we "hide to menu bar"),
        // re-show it for parity with clicking the Dock icon.
        //
        // Note: Don't use "any visible windows" as the gate here — the Quick Panel (NSPanel)
        // can be visible while the main window is still hidden, which would prevent us from
        // restoring the main window on Cmd+Tab.
        if onboardingWindow?.isVisible == true { return }
        if mainWindow?.isVisible != true || mainWindow?.isMiniaturized == true {
            showMainWindow()
        }
    }

    /// Don't quit when window is closed - hide to menu bar instead
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-show window when clicking dock icon
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - NSWindowDelegate

    /// Hide window instead of closing when user clicks close button
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Only intercept the main window close button (hide to menu bar).
        // Other windows (like onboarding) should be allowed to close.
        if sender == mainWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == tickerNextPDFWindow {
            tickerNextPDFWindow = nil
            tickerNextPDFView = nil
            tickerNextCurrentPDFID = nil
            return
        }
        guard window == onboardingWindow else { return }

        // If the user closes onboarding without completing, proceed anyway and don't show again.
        SettingsService.shared.hasCompletedOnboarding = true
        onboardingWindow = nil
        completeStartup()
    }

    // MARK: - Status Item (Menu Bar)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Ticker")
            button.image?.isTemplate = true  // Adapts to menu bar appearance
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleMainWindow()
            return
        }

        if event.type == .rightMouseUp {
            // Right-click shows menu
            let menu = NSMenu()
            menu.addItem(withTitle: "Quick Capture", action: #selector(toggleQuickPanel), keyEquivalent: "l")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Quit Ticker", action: #selector(quitApp), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil  // Clear so left-click works next time
        } else {
            // Left-click toggles window
            toggleMainWindow()
        }
    }

    private func toggleMainWindow() {
        if mainWindow?.isVisible == true {
            mainWindow?.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    @objc private func showMainWindow() {
        if mainWindow?.isMiniaturized == true {
            mainWindow?.deminiaturize(nil)
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleQuickPanel() {
        triggerQuickPanelToggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func selectLibraryFolder() {
        guard SettingsService.tickerNextMode else { return }
        do {
            if let selectedURL = try libraryService.selectLibraryRootInteractively() {
                DebugLog.log("[TickerNext] Selected library folder at \(selectedURL.path)")
                _ = try bootstrapTickerNextLibrary()
            }
        } catch {
            DebugLog.log("[TickerNext] Failed to select library folder (\(DebugLog.errorSummary(error)))")
        }
    }

    @objc private func openTickerNextEditor() {
        guard SettingsService.tickerNextMode else { return }
        _ = ensureTickerNextEditorTextView()
    }

    @objc private func createTickerNextNote() {
        guard SettingsService.tickerNextMode else { return }
        do {
            _ = try ensureLibraryFolderSelected()
            let createdNote = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.createNote(in: rootURL, title: "Untitled")
            }
            if let createdNote {
                showTickerNextNote(createdNote)
                DebugLog.log("[TickerNext] Created note at \(createdNote.url.path)")
            }
        } catch {
            DebugLog.log("[TickerNext] Failed to create note (\(DebugLog.errorSummary(error)))")
        }
    }

    @objc private func openTickerNextNote() {
        guard SettingsService.tickerNextMode else { return }
        do {
            guard let rootURL = try ensureLibraryFolderSelected() else { return }

            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if let markdownType = UTType(filenameExtension: "md") {
                panel.allowedContentTypes = [markdownType]
            }
            panel.allowsMultipleSelection = false
            panel.directoryURL = rootURL
            panel.prompt = "Open Note"
            panel.message = "Choose a Markdown note."

            guard panel.runModal() == .OK, let selectedURL = panel.url else {
                return
            }

            let loadedNote = try libraryService.withLibraryRootAccess { _ in
                try libraryService.loadNote(at: selectedURL)
            }
            if let loadedNote {
                showTickerNextNote(loadedNote)
                DebugLog.log("[TickerNext] Opened note at \(loadedNote.url.path)")
            }
        } catch {
            DebugLog.log("[TickerNext] Failed to open note (\(DebugLog.errorSummary(error)))")
        }
    }

    @objc private func importTickerNextPDF() {
        guard SettingsService.tickerNextMode else { return }
        do {
            _ = try ensureLibraryFolderSelected()

            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.pdf]
            panel.prompt = "Import PDF"
            panel.message = "Choose a PDF to copy into the Ticker Next library."

            guard panel.runModal() == .OK, let selectedURL = panel.url else {
                return
            }

            let didAccessSelectedPDF = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSelectedPDF {
                    selectedURL.stopAccessingSecurityScopedResource()
                }
            }

            let imported = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.importPDF(at: selectedURL, in: rootURL)
            }

            if let imported {
                showTickerNextNote(imported.note)
                DebugLog.log("[TickerNext] Imported PDF at \(imported.importedURL.path)")
            }
        } catch {
            DebugLog.log("[TickerNext] Failed to import PDF (\(DebugLog.errorSummary(error)))")
        }
    }

    @objc private func showTickerNextLinkedPDF() {
        guard let note = tickerNextCurrentNote else { return }
        openTickerNextPDF(for: note)
    }

    @objc private func linkTickerNextPDFSelectionToNote() {
        guard let note = tickerNextCurrentNote,
              note.frontMatter.tickerKind == .pdfNote,
              let pdfID = note.frontMatter.tickerPDFID else {
            NSSound.beep()
            return
        }
        guard tickerNextCurrentPDFID == pdfID else {
            openTickerNextPDF(for: note)
            NSSound.beep()
            return
        }
        guard let pdfView = tickerNextPDFView,
              let selection = pdfView.currentSelection,
              let document = pdfView.document else {
            NSSound.beep()
            return
        }

        let pages = selection.pages
        guard pages.count == 1, let page = pages.first else {
            presentTickerNextPDFDriftWarning(
                title: "Selection Not Supported",
                message: "Select text within a single PDF page to create a note link."
            )
            return
        }

        let selectedText = (selection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else {
            NSSound.beep()
            return
        }

        let pageIndex = document.index(for: page)
        let selectionRect = selection.bounds(for: page)
        let rects = [TickerPDFHighlightRect(selectionRect)]
        let highlightID = UUID()
        let highlight = TickerPDFHighlightAnchor(
            id: highlightID,
            pageIndex: pageIndex,
            selectedText: selectedText,
            rects: rects,
            createdAt: Date()
        )

        do {
            _ = try ensureLibraryFolderSelected()
            _ = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.appendPDFHighlight(
                    pdfID: pdfID,
                    highlight: highlight,
                    in: rootURL
                )
            }
        } catch {
            DebugLog.log("[TickerNext] Failed to persist PDF highlight (\(DebugLog.errorSummary(error)))")
            return
        }

        guard let textView = tickerNextEditorTextView else { return }
        let linkURL = TickerPDFLinkCodec.makeURLString(pdfID: pdfID, highlightID: highlightID)
        let normalizedText = selectedText.replacingOccurrences(of: "\n", with: " ")
        let label = String(normalizedText.prefix(72)).replacingOccurrences(of: "]", with: "")
        let markdownLink = "[\(label)](\(linkURL))"
        let insertion = "\(markdownLink)\n"

        let selectedRange = textView.selectedRange()
        guard textView.shouldChangeText(in: selectedRange, replacementString: insertion) else {
            return
        }
        textView.textStorage?.replaceCharacters(in: selectedRange, with: insertion)
        textView.setSelectedRange(NSRange(location: selectedRange.location + (insertion as NSString).length, length: 0))
        textView.didChangeText()

        persistTickerNextCurrentNoteAndMetadata()
    }

    @objc private func openTickerNextHighlightLinkAtCursor() {
        guard let textView = tickerNextEditorTextView else {
            NSSound.beep()
            return
        }

        let body = textView.string
        let selectionRange = textView.selectedRange()
        guard let parsedLink = resolveTickerNextHighlightLink(
            in: body,
            selectionRange: selectionRange,
            preferredUTF16Offset: selectionRange.location
        ) else {
            NSSound.beep()
            return
        }

        openTickerNextPDFHighlight(pdfID: parsedLink.pdfID, highlightID: parsedLink.highlightID)
    }

    private func resolveTickerNextHighlightLink(
        in body: String,
        selectionRange: NSRange,
        preferredUTF16Offset: Int?
    ) -> (pdfID: UUID, highlightID: UUID)? {
        if let preferredUTF16Offset,
           let match = TickerPDFLinkCodec.match(
               in: body,
               containingUTF16Offset: preferredUTF16Offset
           ) {
            return (match.pdfID, match.highlightID)
        }

        let nsBody = body as NSString
        if selectionRange.length > 0,
           NSMaxRange(selectionRange) <= nsBody.length {
            let selectedText = nsBody.substring(with: selectionRange)
            if let match = TickerPDFLinkCodec.firstMatch(in: selectedText) {
                return (match.pdfID, match.highlightID)
            }
            return TickerPDFLinkCodec.parse(
                urlString: selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return nil
    }

    @objc private func saveTickerNextNote() {
        guard SettingsService.tickerNextMode else { return }
        do {
            if tickerNextCurrentNote == nil {
                createTickerNextNote()
            }
            guard var currentNote = tickerNextCurrentNote else { return }

            guard let textView = tickerNextEditorTextView else { return }
            currentNote.body = textView.string

            _ = try ensureLibraryFolderSelected()
            _ = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.saveNote(currentNote)
                try tickerNextDocMetadataStore.saveSpans(
                    tickerNextAuthorshipSpans,
                    for: currentNote,
                    libraryRootURL: rootURL
                )
            }

            tickerNextCurrentNote = currentNote
            tickerNextPreviousEditorBody = currentNote.body
            DebugLog.log("[TickerNext] Saved note at \(currentNote.url.path)")
        } catch {
            DebugLog.log("[TickerNext] Failed to save note (\(DebugLog.errorSummary(error)))")
        }
    }

    private func triggerQuickPanelToggle() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                self?.quickPanelManager?.toggle()
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.quickPanelManager?.toggle()
        }
    }

    private func bootstrapTickerNextLibraryIfConfigured() {
        guard SettingsService.tickerNextMode else { return }

        do {
            var resolvedRootURL: URL?
            if let existingRootURL = try libraryService.withLibraryRootAccess({ rootURL -> URL in
                try libraryService.ensureLibraryStructure(at: rootURL)
                return rootURL
            }) {
                resolvedRootURL = existingRootURL
            } else {
                resolvedRootURL = try libraryService.selectLibraryRootInteractively()
            }

            guard let resolvedRootURL else {
                showTickerNextStartupPlaceholder(
                    "Choose a library folder from Ticker Next > Set Library Folder... to get started."
                )
                return
            }

            DebugLog.log("[TickerNext] Library structure ready at \(resolvedRootURL.path)")
            try showTickerNextStartupNote(in: resolvedRootURL)
        } catch {
            DebugLog.log("[TickerNext] Failed to bootstrap library structure (\(DebugLog.errorSummary(error)))")
            showTickerNextStartupPlaceholder(
                "Ticker Next could not open the library. Use Ticker Next > Set Library Folder... and try again."
            )
        }
    }

    private func setupMainWindow() {
        // Position window to cover right 3/8 of screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let windowWidth = screenFrame.width * 3 / 8
        let windowRect = NSRect(
            x: screenFrame.maxX - windowWidth,
            y: screenFrame.minY,
            width: windowWidth,
            height: screenFrame.height
        )

        mainWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        mainWindow?.title = SettingsService.tickerNextMode ? "Ticker Next Editor" : "Ticker"
        mainWindow?.minSize = NSSize(width: 300, height: 400)
        mainWindow?.delegate = self  // Handle close to hide instead of quit
        mainWindow?.level = .floating  // Always on top
        mainWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if SettingsService.tickerNextMode {
            webViewManager = nil

            let textView = TickerNextEditorTextView(frame: .zero)
            configureTickerNextEditorTextView(textView)
            let scrollView = makeTickerNextEditorScrollView(with: textView)

            mainWindow?.contentView = scrollView
            tickerNextEditorWindow = mainWindow
            tickerNextEditorTextView = textView
        } else {
            webViewManager = WebViewManager()
            mainWindow?.contentView = webViewManager?.webView
            webViewManager?.load()
        }

        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Quick Panel Setup

    private func setupQuickPanel() {
        // Initialize Quick Panel manager on main actor
        Task { @MainActor in
            let manager = QuickPanelManager()
            self.quickPanelManager = manager

            // Configure with services from WebViewManager
            if let wvm = self.webViewManager,
               let persistence = wvm.persistence {
                manager.configure(
                    persistence: persistence,
                    bridgeService: wvm.bridgeService,
                    orchestrator: wvm.orchestrator
                )
            }
        }

        // Initialize hotkey service
        hotkeyService = HotkeyService()

        // Register Quick Panel hotkey (Cmd+L)
        hotkeyService?.register(config: .quickPanel) { [weak self] in
            self?.triggerQuickPanelToggle()
        }

        // Register deprecated screenshot hotkey (Cmd+;).
        // We keep the binding for discoverability while app-initiated capture is disabled.
        hotkeyService?.register(config: .screenshot) { [weak self] in
            Task { @MainActor in
                self?.handleDeprecatedScreenshotHotkey()
            }
        }

        // Register Main Window toggle hotkey (Ctrl+Space)
        hotkeyService?.register(config: .mainWindow) { [weak self] in
            Task { @MainActor in
                self?.toggleMainWindow()
            }
        }
    }

    /// Deprecated until we migrate to a Sequoia-style picker flow.
    /// Users can still attach screenshots by capturing to clipboard with macOS, then pressing Cmd+L.
    @MainActor
    private func handleDeprecatedScreenshotHotkey() {
        quickPanelManager?.showWithStatusMessage(
            "Screenshot mode is deprecated. Use macOS screenshot shortcuts, then press Cmd+L."
        )
    }

    private func setupTickerNextObservers() {
        guard SettingsService.tickerNextMode else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTickerNextCaptureAppend(_:)),
            name: .tickerNextDidAppendCaptureToNote,
            object: nil
        )
    }

    @objc private func handleTickerNextCaptureAppend(_ notification: Notification) {
        guard let notePath = notification.userInfo?[TickerNextQuickCaptureUserInfoKey.notePath] as? String,
              let appendedMarkdown = notification.userInfo?[TickerNextQuickCaptureUserInfoKey.appendedMarkdown] as? String else {
            return
        }

        guard tickerNextCurrentNote?.url.path == notePath else { return }
        guard let textView = tickerNextEditorTextView else { return }

        let updatedBody = appendMarkdownBlock(appendedMarkdown, to: textView.string)
        tickerNextSuppressTextDidChange = true
        textView.string = updatedBody
        tickerNextSuppressTextDidChange = false
        syncTickerNextEditorStateAfterTextChange(newBody: updatedBody)
    }

    private func ensureLibraryFolderSelected() throws -> URL? {
        if let rootURL = try libraryService.resolveLibraryRootURL() {
            return rootURL
        }
        return try libraryService.selectLibraryRootInteractively()
    }

    private func bootstrapTickerNextLibrary() throws -> String? {
        try libraryService.withLibraryRootAccess { rootURL in
            try libraryService.ensureLibraryStructure(at: rootURL)
            return rootURL.path
        }
    }

    @discardableResult
    private func ensureTickerNextEditorTextView() -> NSTextView {
        if let existingTextView = tickerNextEditorTextView, let existingWindow = tickerNextEditorWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existingTextView
        }

        let textView = TickerNextEditorTextView(frame: .zero)
        configureTickerNextEditorTextView(textView)
        let scrollView = makeTickerNextEditorScrollView(with: textView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ticker Next Editor"
        window.contentView = scrollView
        window.center()
        window.makeKeyAndOrderFront(nil)

        tickerNextEditorWindow = window
        tickerNextEditorTextView = textView
        NSApp.activate(ignoringOtherApps: true)

        return textView
    }

    private func configureTickerNextEditorTextView(_ textView: TickerNextEditorTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let textColor = NSColor.labelColor
        let backgroundColor = NSColor.textBackgroundColor

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = textColor
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        textView.delegate = self
        textView.actionHandler = self
    }

    private func makeTickerNextEditorScrollView(with textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.documentView = textView
        return scrollView
    }

    private func showTickerNextStartupNote(in rootURL: URL) throws {
        if let notePath = SettingsService.shared.tickerNextCurrentNotePath,
           !notePath.isEmpty {
            let noteURL = URL(fileURLWithPath: notePath)
            if FileManager.default.fileExists(atPath: noteURL.path) {
                let note = try libraryService.loadNote(at: noteURL)
                showTickerNextNote(note)
                return
            }
        }

        let inboxNote = try libraryService.ensureInboxNote(in: rootURL)
        showTickerNextNote(inboxNote)
    }

    private func showTickerNextStartupPlaceholder(_ message: String) {
        let textView = ensureTickerNextEditorTextView()
        tickerNextCurrentNote = nil
        tickerNextAuthorshipSpans = []
        tickerNextPreviousEditorBody = ""
        tickerNextPendingAIInsertion = nil
        tickerNextAIRequestInFlight = false
        tickerNextSuppressTextDidChange = true
        textView.string = message
        tickerNextSuppressTextDidChange = false
        applyTickerNextAuthorshipStyling()
        tickerNextEditorWindow?.title = "Ticker Next Editor"
    }

    private func showTickerNextNote(_ note: TickerMarkdownNote) {
        let textView = ensureTickerNextEditorTextView()
        tickerNextCurrentNote = note
        SettingsService.shared.tickerNextCurrentNotePath = note.url.path
        tickerNextPendingAIInsertion = nil
        tickerNextAIRequestInFlight = false
        loadTickerNextAuthorshipSpans(for: note)
        tickerNextSuppressTextDidChange = true
        textView.string = note.body
        tickerNextSuppressTextDidChange = false
        tickerNextPreviousEditorBody = note.body
        applyTickerNextAuthorshipStyling()
        tickerNextEditorWindow?.title = note.url.lastPathComponent
        checkTickerNextPDFDriftIfNeeded(for: note)
        if note.frontMatter.tickerKind == .pdfNote {
            openTickerNextPDF(for: note)
        }
    }

    private func ensureTickerNextPDFView() -> PDFView {
        if let existingPDFView = tickerNextPDFView, let existingWindow = tickerNextPDFWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existingPDFView
        }

        let pdfView = PDFView(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ticker Next PDF"
        window.contentView = pdfView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        tickerNextPDFWindow = window
        tickerNextPDFView = pdfView
        NSApp.activate(ignoringOtherApps: true)

        return pdfView
    }

    private func openTickerNextPDF(for note: TickerMarkdownNote) {
        guard note.frontMatter.tickerKind == .pdfNote,
              let pdfID = note.frontMatter.tickerPDFID else {
            return
        }

        do {
            _ = try ensureLibraryFolderSelected()
            let payload = try libraryService.withLibraryRootAccess { rootURL -> (URL, PDFDocument)? in
                let pdfURL = libraryService.importedPDFURL(for: pdfID, in: rootURL)
                guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                    return nil
                }
                let pdfData = try Data(contentsOf: pdfURL, options: [.mappedIfSafe])
                guard let document = PDFDocument(data: pdfData) else {
                    return nil
                }
                return (pdfURL, document)
            } ?? nil

            guard let payload else {
                return
            }

            let pdfView = ensureTickerNextPDFView()
            pdfView.document = payload.1
            tickerNextCurrentPDFID = pdfID
            tickerNextPDFWindow?.title = payload.0.lastPathComponent
        } catch {
            DebugLog.log("[TickerNext] Failed to open linked PDF (\(DebugLog.errorSummary(error)))")
        }
    }

    private func openTickerNextPDFHighlight(pdfID: UUID, highlightID: UUID) {
        do {
            _ = try ensureLibraryFolderSelected()

            let payload = try libraryService.withLibraryRootAccess { rootURL -> (URL, PDFDocument, TickerPDFHighlightAnchor)? in
                let pdfURL = libraryService.importedPDFURL(for: pdfID, in: rootURL)
                guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                    return nil
                }
                guard let highlight = try libraryService.loadPDFHighlight(
                    pdfID: pdfID,
                    highlightID: highlightID,
                    in: rootURL
                ) else {
                    return nil
                }
                let pdfData = try Data(contentsOf: pdfURL, options: [.mappedIfSafe])
                guard let document = PDFDocument(data: pdfData) else {
                    return nil
                }
                return (pdfURL, document, highlight)
            } ?? nil

            guard let payload else {
                NSSound.beep()
                return
            }

            let pdfView = ensureTickerNextPDFView()
            pdfView.document = payload.1
            tickerNextCurrentPDFID = pdfID
            tickerNextPDFWindow?.title = payload.0.lastPathComponent
            jumpTickerNextPDFView(pdfView, to: payload.2)
        } catch {
            DebugLog.log("[TickerNext] Failed to open PDF highlight (\(DebugLog.errorSummary(error)))")
            NSSound.beep()
        }
    }

    private func jumpTickerNextPDFView(_ pdfView: PDFView, to highlight: TickerPDFHighlightAnchor) {
        guard let document = pdfView.document,
              let page = document.page(at: highlight.pageIndex) else {
            return
        }

        let destinationPoint: CGPoint
        if let firstRect = highlight.rects.first?.cgRect {
            destinationPoint = CGPoint(x: firstRect.midX, y: firstRect.maxY)
        } else {
            destinationPoint = CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)
        }

        let destination = PDFDestination(page: page, at: destinationPoint)
        pdfView.go(to: destination)

        if let firstRect = highlight.rects.first?.cgRect,
           let selection = page.selection(for: firstRect) {
            pdfView.setCurrentSelection(selection, animate: true)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !tickerNextSuppressTextDidChange else { return }
        guard let textView = notification.object as? NSTextView,
              textView == tickerNextEditorTextView else {
            return
        }

        syncTickerNextEditorStateAfterTextChange(newBody: textView.string)
    }

    func tickerNextEditorTextView(
        _ textView: TickerNextEditorTextView,
        didRequestAction action: TickerNextSelectionAIAction
    ) {
        guard textView == tickerNextEditorTextView else { return }
        runTickerNextSelectionAIAction(action)
    }

    func tickerNextEditorTextView(
        _ textView: TickerNextEditorTextView,
        didCommandClickAtUTF16Offset offset: Int
    ) -> Bool {
        guard textView == tickerNextEditorTextView else { return false }
        guard let parsedLink = resolveTickerNextHighlightLink(
            in: textView.string,
            selectionRange: textView.selectedRange(),
            preferredUTF16Offset: offset
        ) else {
            return false
        }

        openTickerNextPDFHighlight(pdfID: parsedLink.pdfID, highlightID: parsedLink.highlightID)
        return true
    }

    private func syncTickerNextEditorStateAfterTextChange(newBody: String) {
        let oldBody = tickerNextPreviousEditorBody

        if oldBody != newBody,
           let edit = TickerNextTextEditDetector.detectSingleEdit(from: oldBody, to: newBody) {
            tickerNextAuthorshipSpans = TickerNextAuthorshipSpanTransformer.applyUserEdit(
                spans: tickerNextAuthorshipSpans,
                edit: edit
            )
        }

        var shouldPersist = false
        if let pending = tickerNextPendingAIInsertion {
            tickerNextAuthorshipSpans = TickerNextAuthorshipSpanTransformer.addAIInsertion(
                range: pending.range,
                source: pending.source,
                to: tickerNextAuthorshipSpans
            )
            tickerNextPendingAIInsertion = nil
            shouldPersist = true
        }

        let textLength = (newBody as NSString).length
        tickerNextAuthorshipSpans = TickerNextAuthorshipSpanTransformer.clamped(
            spans: tickerNextAuthorshipSpans,
            toUTF16Length: textLength
        )

        tickerNextPreviousEditorBody = newBody
        tickerNextCurrentNote?.body = newBody
        applyTickerNextAuthorshipStyling()

        if shouldPersist {
            persistTickerNextCurrentNoteAndMetadata()
        }
    }

    private func runTickerNextSelectionAIAction(_ action: TickerNextSelectionAIAction) {
        guard !tickerNextAIRequestInFlight else { return }
        guard let textView = tickerNextEditorTextView else { return }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else {
            NSSound.beep()
            return
        }

        let buffer = textView.string as NSString
        guard NSMaxRange(selectedRange) <= buffer.length else {
            NSSound.beep()
            return
        }

        let selectedText = buffer.substring(with: selectedRange)

        let rewriteInstruction: String?
        if action == .rewrite {
            guard let instruction = promptForTickerNextRewriteInstruction() else {
                return
            }
            rewriteInstruction = instruction
        } else {
            rewriteInstruction = nil
        }

        tickerNextAIRequestInFlight = true
        textView.isEditable = false
        tickerNextEditorWindow?.title = "Ticker Next Editor (AI...)"

        Task {
            do {
                let replacement = try await tickerNextSelectionAIService.transformSelection(
                    selectedText,
                    action: action,
                    customInstruction: rewriteInstruction
                )

                await MainActor.run {
                    self.applyTickerNextAIReplacement(
                        with: replacement,
                        replacing: selectedRange,
                        source: action.rawValue
                    )
                }
            } catch {
                await MainActor.run {
                    self.presentTickerNextAIActionError(error)
                }
            }

            await MainActor.run {
                self.tickerNextAIRequestInFlight = false
                self.tickerNextEditorTextView?.isEditable = true
                self.tickerNextEditorWindow?.title = self.tickerNextCurrentNote?.url.lastPathComponent ?? "Ticker Next Editor"
            }
        }
    }

    private func applyTickerNextAIReplacement(
        with replacement: String,
        replacing range: NSRange,
        source: String
    ) {
        guard let textView = tickerNextEditorTextView else { return }

        let bufferLength = (textView.string as NSString).length
        let safeLocation = min(max(0, range.location), bufferLength)
        let safeLength = min(max(0, range.length), bufferLength - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        guard safeRange.length > 0 else { return }

        let insertedLength = (replacement as NSString).length
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        guard textView.shouldChangeText(in: safeRange, replacementString: replacement) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: safeRange, with: replacement)
        textView.setSelectedRange(NSRange(location: safeRange.location + insertedLength, length: 0))
        tickerNextPendingAIInsertion = (
            range: NSRange(location: safeRange.location, length: insertedLength),
            source: source
        )
        textView.didChangeText()
    }

    private func promptForTickerNextRewriteInstruction() -> String? {
        let alert = NSAlert()
        alert.messageText = "Rewrite Selection"
        alert.informativeText = "Describe how the selected text should be rewritten."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rewrite")
        alert.addButton(withTitle: "Cancel")

        let promptField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        promptField.placeholderString = "e.g. Make this more concise and technical."
        alert.accessoryView = promptField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            NSSound.beep()
            return nil
        }
        return prompt
    }

    private func presentTickerNextAIActionError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "AI action failed"
        alert.informativeText = DebugLog.errorSummary(error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func loadTickerNextAuthorshipSpans(for note: TickerMarkdownNote) {
        do {
            let spans = try libraryService.withLibraryRootAccess { rootURL in
                try tickerNextDocMetadataStore.loadSpans(for: note, libraryRootURL: rootURL)
            } ?? []

            tickerNextAuthorshipSpans = TickerNextAuthorshipSpanTransformer.clamped(
                spans: spans,
                toUTF16Length: (note.body as NSString).length
            )
        } catch {
            tickerNextAuthorshipSpans = []
            DebugLog.log("[TickerNext] Failed to load authorship metadata (\(DebugLog.errorSummary(error)))")
        }
    }

    private func applyTickerNextAuthorshipStyling() {
        guard let textView = tickerNextEditorTextView,
              let layoutManager = textView.layoutManager else {
            return
        }

        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let baseColor = NSColor.labelColor

        textView.font = baseFont
        textView.textColor = baseColor
        textView.insertionPointColor = baseColor
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: baseColor
        ]

        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttribute(.font, value: baseFont, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttribute(.foregroundColor, value: baseColor, forCharacterRange: fullRange)

        guard !tickerNextAuthorshipSpans.isEmpty else { return }

        let aiFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
        let aiColor = NSColor.labelColor.withAlphaComponent(0.8)

        for span in tickerNextAuthorshipSpans {
            guard span.lengthUTF16 > 0 else { continue }
            let maxLength = fullRange.length - span.startUTF16
            guard span.startUTF16 >= 0, maxLength > 0 else { continue }
            let appliedRange = NSRange(
                location: span.startUTF16,
                length: min(span.lengthUTF16, maxLength)
            )
            layoutManager.addTemporaryAttribute(.font, value: aiFont, forCharacterRange: appliedRange)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: aiColor, forCharacterRange: appliedRange)
        }
    }

    private func persistTickerNextCurrentNoteAndMetadata() {
        guard var note = tickerNextCurrentNote else { return }
        if let textView = tickerNextEditorTextView {
            note.body = textView.string
        }

        do {
            _ = try ensureLibraryFolderSelected()
            _ = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.saveNote(note)
                try tickerNextDocMetadataStore.saveSpans(
                    tickerNextAuthorshipSpans,
                    for: note,
                    libraryRootURL: rootURL
                )
            }
            tickerNextCurrentNote = note
            tickerNextPreviousEditorBody = note.body
        } catch {
            DebugLog.log("[TickerNext] Failed to persist note metadata (\(DebugLog.errorSummary(error)))")
        }
    }

    private func checkTickerNextPDFDriftIfNeeded(for note: TickerMarkdownNote) {
        guard note.frontMatter.tickerKind == .pdfNote,
              let pdfID = note.frontMatter.tickerPDFID else {
            return
        }

        do {
            let status = try libraryService.withLibraryRootAccess { rootURL in
                try libraryService.inspectPDFDrift(for: pdfID, in: rootURL)
            }

            guard let status else { return }

            switch status {
            case .matches:
                return

            case .missingFile:
                presentTickerNextPDFDriftWarning(
                    title: "Linked PDF Missing",
                    message: "Ticker Next cannot find the imported PDF file linked to this note."
                )

            case .missingMetadata(let current):
                _ = try libraryService.withLibraryRootAccess { rootURL in
                    try libraryService.savePDFMetadata(pdfID: pdfID, fingerprint: current, in: rootURL)
                }
                DebugLog.log("[TickerNext] Bootstrapped missing PDF metadata for \(pdfID.uuidString.lowercased())")

            case .drifted(let expected, let current):
                let message = """
                The linked PDF has changed since import.

                Stored: \(expected.fileSize) bytes
                Current: \(current.fileSize) bytes
                """
                presentTickerNextPDFDriftWarning(
                    title: "Linked PDF Has Changed",
                    message: message
                )
            }
        } catch {
            DebugLog.log("[TickerNext] PDF drift check failed (\(DebugLog.errorSummary(error)))")
        }
    }

    private func presentTickerNextPDFDriftWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func appendMarkdownBlock(_ block: String, to body: String) -> String {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block
        }

        var updatedBody = body
        if !updatedBody.hasSuffix("\n") {
            updatedBody += "\n"
        }
        if !updatedBody.hasSuffix("\n\n") {
            updatedBody += "\n"
        }
        updatedBody += block
        return updatedBody
    }
}
