import AppKit
import Carbon

/// Configuration for a single hotkey
struct HotkeyConfig {
    let keyCode: UInt32
    let modifiers: UInt32
    let id: UInt32

    // Common hotkey configurations
    static let quickPanel = HotkeyConfig(
        keyCode: 37,                    // L
        modifiers: UInt32(cmdKey),      // Command
        id: 1
    )

    static let screenshot = HotkeyConfig(
        keyCode: 41,                    // Semicolon
        modifiers: UInt32(cmdKey),      // Command
        id: 2
    )

    static let mainWindow = HotkeyConfig(
        keyCode: 49,                    // Space
        modifiers: UInt32(controlKey),  // Control
        id: 3
    )
}

/// Global hotkey service using Carbon RegisterEventHotKey
/// Supports multiple hotkeys with different callbacks
/// Works WITHOUT accessibility permissions
final class HotkeyService {

    // Static reference for the C callback
    private static var sharedInstance: HotkeyService?

    private var handlerRef: EventHandlerRef?
    private var registeredHotkeys: [UInt32: RegisteredHotkey] = [:]

    private struct RegisteredHotkey {
        let config: HotkeyConfig
        let callback: () -> Void
        var ref: EventHotKeyRef?
    }

    // Signature for all Ticker hotkeys (4-char code "TICK")
    private let hotkeySignature: OSType = 0x5449434B

    init() {
        HotkeyService.sharedInstance = self
        installEventHandler()
    }

    deinit {
        unregisterAll()
        HotkeyService.sharedInstance = nil
    }

    // MARK: - Public API

    /// Register a hotkey with a callback
    func register(config: HotkeyConfig, callback: @escaping () -> Void) {
        // Don't re-register if already registered
        if registeredHotkeys[config.id] != nil {
            unregister(id: config.id)
        }

        let hotKeyID = EventHotKeyID(
            signature: hotkeySignature,
            id: config.id
        )

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            registeredHotkeys[config.id] = RegisteredHotkey(
                config: config,
                callback: callback,
                ref: ref
            )
            DebugLog.log("[HotkeyService] Registered hotkey id=\(config.id)")
        } else {
            DebugLog.log("[HotkeyService] Failed to register hotkey id=\(config.id), status=\(status)")
        }
    }

    /// Unregister a specific hotkey by ID
    func unregister(id: UInt32) {
        if let registered = registeredHotkeys[id], let ref = registered.ref {
            UnregisterEventHotKey(ref)
            registeredHotkeys.removeValue(forKey: id)
        }
    }

    /// Unregister all hotkeys
    func unregisterAll() {
        for (id, registered) in registeredHotkeys {
            if let ref = registered.ref {
                UnregisterEventHotKey(ref)
            }
            registeredHotkeys.removeValue(forKey: id)
        }

        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }

    // MARK: - Private

    /// Install the Carbon event handler (called once during init)
    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // C function pointer for the handler
        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            HotkeyService.sharedInstance?.handleHotkeyEvent(event)
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )

        if status == noErr {
            self.handlerRef = handlerRef
        }
    }

    /// Handle a hotkey event by dispatching to the correct callback
    private func handleHotkeyEvent(_ event: EventRef?) {
        guard let event = event else { return }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr else { return }

        // Find and call the registered callback
        if let registered = registeredHotkeys[hotkeyID.id] {
            registered.callback()
        }
    }
}
