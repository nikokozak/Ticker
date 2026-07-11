import AppKit
import SwiftUI
import WebKit
import ApplicationServices
import Sparkle

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

enum TickerURLCommand: Equatable {
    enum StreamSelector: Equatable {
        case id(UUID)
        case title(String)
    }

    case append(stream: StreamSelector, text: String)
    case open(streamId: UUID)

    static let maxAppendTextLength = 10_000

    static func parse(_ url: URL) -> TickerURLCommand? {
        guard url.scheme?.lowercased() == "ticker",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let action = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = components.queryItems ?? []
        func query(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        switch action {
        case "append":
            guard let streamValue = query("stream")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !streamValue.isEmpty,
                  let text = query("text"),
                  !text.isEmpty,
                  text.count <= maxAppendTextLength else {
                return nil
            }
            let selector = UUID(uuidString: streamValue).map(StreamSelector.id) ?? .title(streamValue)
            return .append(stream: selector, text: text)
        case "open":
            guard let streamValue = query("stream"),
                  let streamId = UUID(uuidString: streamValue) else {
                return nil
            }
            return .open(streamId: streamId)
        default:
            return nil
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var serviceContainer: ServiceContainer?
    private var webViewManager: WebViewManager?
    private var onboardingWindow: NSWindow?
    private var didCompleteStartup = false
    private var skipLastStreamRestore = false

    // Menu bar (status item)
    private var statusItem: NSStatusItem?

    // Quick Panel services
    private var hotkeyService: HotkeyService?
    private var quickPanelManager: QuickPanelManager?
    private var pdfFindKeyMonitor: Any?

    // Sparkle updater (lives for app lifetime). Delegate is self so we can clear the
    // crash sentinel before Sparkle relaunches — an update relaunch does not reliably
    // fire applicationWillTerminate, which would otherwise report a false crash.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashSessionSentinel.markLaunch()
        setupStatusItem()
        setupMenuBar()
        setupAppearanceObserver()

        // Alpha: proxy-only onboarding (no vendor API keys).
        if SettingsService.shared.needsOnboarding {
            showOnboarding()
        } else {
            completeStartup()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Complete startup after onboarding (or skip if not needed)
    @MainActor
    private func completeStartup() {
        guard !didCompleteStartup else { return }
        didCompleteStartup = true
        let container = ServiceContainer()
        serviceContainer = container
        setupMainWindow(container: container)
        setupPDFFindKeyRouting()
        setupQuickPanel(container: container)
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
            Task { @MainActor in
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.completeStartup()
            }
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
        CrashSessionSentinel.markCleanTermination()
        if let pdfFindKeyMonitor {
            NSEvent.removeMonitor(pdfFindKeyMonitor)
            self.pdfFindKeyMonitor = nil
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        skipLastStreamRestore = true
        webViewManager?.skipLaunchStreamRestore()
        DebugLog.log("[Ticker] File-open event ignored; skipping last stream restore")
        sender.reply(toOpenOrPrint: .failure)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        skipLastStreamRestore = true
        webViewManager?.skipLaunchStreamRestore()
        for url in urls {
            handleTickerURL(url)
        }
    }

    @MainActor
    private func handleTickerURL(_ url: URL) {
        guard let command = TickerURLCommand.parse(url) else {
            DebugLog.log("[TickerURL] Ignored malformed URL: \(url.absoluteString)")
            return
        }
        guard let persistence = serviceContainer?.persistence else {
            DebugLog.log("[TickerURL] Persistence unavailable")
            return
        }

        do {
            switch command {
            case .open(let streamId):
                guard try persistence.loadStream(id: streamId) != nil else {
                    DebugLog.log("[TickerURL] Open ignored; stream not found: \(streamId.uuidString)")
                    return
                }
                webViewManager?.openStream(id: streamId)

            case .append(let selector, let text):
                guard let streamId = try resolveTickerStream(selector, persistence: persistence) else {
                    return
                }
                let span = ProvenanceSpan(
                    streamId: streamId,
                    start: 0,
                    end: UTF16Offsets.utf16Length(text),
                    origin: "capture",
                    meta: QuickPanelMarkdownFormatter.metadataJSON(["sourceApp": "ticker://"]),
                    textHash: FNV1a.hash(text)
                )
                let result = try persistence.appendToStreamDocument(streamId: streamId, fragment: text, spans: [span])
                serviceContainer?.bridgeService.send(BridgeMessage(type: "streamDocumentAppended", payload: [
                    "streamId": AnyCodable(streamId.uuidString),
                    "fragment": AnyCodable(result.fragment),
                    "revision": AnyCodable(result.revision),
                    "isNewStream": AnyCodable(false),
                    "source": AnyCodable("urlScheme"),
                    "spans": AnyCodable(StreamCodec.encodeSpans(result.spans))
                ]))
            }
        } catch {
            DebugLog.log("[TickerURL] Failed to handle URL (\(DebugLog.errorSummary(error)))")
        }
    }

    private func resolveTickerStream(_ selector: TickerURLCommand.StreamSelector, persistence: PersistenceService) throws -> UUID? {
        switch selector {
        case .id(let id):
            if try persistence.loadStream(id: id) != nil {
                return id
            }
            DebugLog.log("[TickerURL] Append ignored; stream ID not found: \(id.uuidString)")
            return nil
        case .title(let title):
            switch try persistence.resolveUniqueStreamTitle(title) {
            case .unique(let id):
                return id
            case .notFound:
                DebugLog.log("[TickerURL] Append ignored; stream title not found: \(title)")
                return nil
            case .ambiguous:
                DebugLog.log("[TickerURL] Append ignored; duplicate title requires a stream UUID: \(title)")
                return nil
            }
        }
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

    private func setupPDFFindKeyRouting() {
        guard pdfFindKeyMonitor == nil else { return }
        pdfFindKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window == self.mainWindow else {
                return event
            }

            if MainActor.assumeIsolated({ [weak self] in
                self?.webViewManager?.handlePDFFindBarKeyEvent(event) == true
            }) {
                return nil
            }

            guard self.isCommandFindEvent(event) else {
                return event
            }

            let handled = MainActor.assumeIsolated { [weak self] in
                self?.webViewManager?.handlePDFFindShortcutIfFocused() == true
            }
            return handled ? nil : event
        }
    }

    private func isCommandFindEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && !flags.contains(.option)
            && !flags.contains(.control)
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    @MainActor
    private func setupMainWindow(container: ServiceContainer) {
        let autosaveName = "TickerMainWindow"
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
        let windowRect: NSRect
        if hasSavedFrame {
            windowRect = NSRect(x: 0, y: 0, width: 900, height: 700)
        } else {
            // Position window to cover right 3/8 of screen on first launch.
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let screenFrame = screen.visibleFrame
            let windowWidth = screenFrame.width * 3 / 8
            windowRect = NSRect(
                x: screenFrame.maxX - windowWidth,
                y: screenFrame.minY,
                width: windowWidth,
                height: screenFrame.height
            )
        }

        mainWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        mainWindow?.title = "Ticker"
        mainWindow?.styleMask.insert(.fullSizeContentView)
        mainWindow?.titlebarAppearsTransparent = true
        mainWindow?.titleVisibility = .hidden
        mainWindow?.backgroundColor = NativePalette.background
        mainWindow?.minSize = NSSize(width: 300, height: 400)
        mainWindow?.delegate = self  // Handle close to hide instead of quit
        _ = mainWindow?.setFrameAutosaveName(autosaveName)
        if hasSavedFrame {
            _ = mainWindow?.setFrameUsingName(autosaveName)
        }

        webViewManager = WebViewManager(container: container)
        if skipLastStreamRestore {
            webViewManager?.skipLaunchStreamRestore()
        }
        mainWindow?.contentView = webViewManager?.rootView
        webViewManager?.load()

        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Quick Panel Setup

    @MainActor
    private func setupQuickPanel(container: ServiceContainer) {
        let manager = QuickPanelManager(aiOperations: container.aiOperations)
        quickPanelManager = manager
        manager.configure(container: container)
        manager.configureLocalSelectionProvider(QuickPanelLocalSelectionProvider(
            pdfSelection: { [weak self] in
                self?.webViewManager?.currentPDFSelectionText()
            },
            editorSelection: { [weak self] in
                guard let webViewManager = self?.webViewManager else {
                    return nil
                }
                return await webViewManager.requestEditorSelection()
            }
        ))

        // Initialize hotkey service
        hotkeyService = HotkeyService()

        // Register Quick Panel hotkey (Cmd+L)
        hotkeyService?.register(config: .quickPanel) { [weak self] in
            self?.triggerQuickPanelToggle()
        }

        // Register Main Window toggle hotkey (Ctrl+Space)
        hotkeyService?.register(config: .mainWindow) { [weak self] in
            Task { @MainActor in
                self?.toggleMainWindow()
            }
        }
    }

}

extension AppDelegate: SPUUpdaterDelegate {
    /// Sparkle relaunches the app to finish an update; that path does not reliably fire
    /// applicationWillTerminate, so clear the crash sentinel here to avoid a false
    /// "last session crashed" in the first feedback after an update.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        CrashSessionSentinel.markCleanTermination()
    }
}
