import Foundation

final class SettingsMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "loadSettings",
        "saveSettings"
    ]

    private let settingsService: SettingsService
    private let bridgeService: BridgeService
    private let settingsProvider: () -> [String: Any]

    init(container: ServiceContainer, settingsProvider: @escaping () -> [String: Any]) {
        self.settingsService = container.settingsService
        self.bridgeService = container.bridgeService
        self.settingsProvider = settingsProvider
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "loadSettings":
            let settings = settingsProvider()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))

        case "saveSettings":
            guard let payload = message.payload else {
                DebugLog.log("[WebViewManager] Invalid saveSettings payload")
                return
            }

            // Save OpenAI API key if provided
            if let openaiKey = payload["openaiAPIKey"]?.value as? String {
                settingsService.openaiAPIKey = openaiKey.isEmpty ? nil : openaiKey
            }

            // Save Anthropic API key if provided
            if let anthropicKey = payload["anthropicAPIKey"]?.value as? String {
                settingsService.anthropicAPIKey = anthropicKey.isEmpty ? nil : anthropicKey
            }

            // Save Perplexity API key if provided
            if let perplexityKey = payload["perplexityAPIKey"]?.value as? String {
                settingsService.perplexityAPIKey = perplexityKey.isEmpty ? nil : perplexityKey
            }

            // Save smart routing setting if provided
            if let smartRouting = payload["smartRoutingEnabled"]?.value as? Bool {
                settingsService.smartRoutingEnabled = smartRouting
            }

            // Save default model setting if provided
            if let modelValue = payload["defaultModel"]?.value as? String,
               let model = SettingsService.DefaultModel(rawValue: modelValue) {
                settingsService.defaultModel = model
            }

            // Save appearance setting if provided
            if let appearanceValue = payload["appearance"]?.value as? String,
               let appearance = SettingsService.Appearance(rawValue: appearanceValue) {
                settingsService.appearance = appearance
                // Notify AppDelegate to update window appearances
                NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
            }

            // Save diagnostics setting if provided
            if let diagnosticsEnabled = payload["diagnosticsEnabled"]?.value as? Bool {
                settingsService.diagnosticsEnabled = diagnosticsEnabled
            }

            // Save editor font setting if provided
            if let editorFontValue = payload["editorFont"]?.value as? String,
               let editorFont = SettingsService.EditorFont(rawValue: editorFontValue) {
                settingsService.editorFont = editorFont
            }

            // Save editor font size setting if provided
            if let editorFontSize = payload["editorFontSize"]?.value as? Double {
                settingsService.editorFontSize = editorFontSize
            } else if let editorFontSize = payload["editorFontSize"]?.value as? NSNumber {
                settingsService.editorFontSize = editorFontSize.doubleValue
            }

            // Save editor line spacing setting if provided
            if let editorLineSpacing = payload["editorLineSpacing"]?.value as? Double {
                settingsService.editorLineSpacing = editorLineSpacing
            } else if let editorLineSpacing = payload["editorLineSpacing"]?.value as? NSNumber {
                settingsService.editorLineSpacing = editorLineSpacing.doubleValue
            }

            // Send back updated settings
            let settings = settingsProvider()
            bridgeService.send(BridgeMessage(
                type: "settingsLoaded",
                payload: ["settings": AnyCodable(settings)]
            ))

        default:
            DebugLog.log("[SettingsMessageHandler] Unknown message type: \(message.type)")
        }
    }
}
