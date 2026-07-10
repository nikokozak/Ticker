import Foundation
import AppKit

/// Settings storage for non-sensitive preferences.
final class SettingsService {
    static let shared = SettingsService()

    private let defaults: UserDefaults
    /// Proxy-only mode: all LLM calls must go through Ticker Proxy.
    /// When true, local vendor API calls (OpenAI, Anthropic, Perplexity) are disabled at runtime.
    static let proxyOnlyMode = true

    // UserDefaults keys (non-sensitive settings)
    private enum Keys {
        static let defaultModel = "default_model"
        static let appearance = "appearance"
        static let editorFont = "editor_font"
        static let editorFontSize = "editor_font_size"
        static let editorLineSpacing = "editor_line_spacing"
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let diagnosticsEnabled = "diagnostics_enabled"
    }

    enum Appearance: String {
        case light = "light"
        case dark = "dark"
        case system = "system"
    }

    enum DefaultModel: String {
        case openai = "openai"
        case openaiFast = "openaiFast"
        case anthropic = "anthropic"

        /// Proxy provider name for this choice.
        var provider: String {
            switch self {
            case .openai, .openaiFast: return "openai"
            case .anthropic: return "anthropic"
            }
        }

        /// Explicit model to request, or "default" to use the proxy's default.
        var proxyModel: String {
            switch self {
            case .openai, .anthropic: return "default"
            case .openaiFast: return "gpt-4o-mini"
            }
        }
    }

    enum EditorFont: String {
        case systemSans = "systemSans"
        case humanistSans = "humanistSans"
        case monoSans = "monoSans"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Onboarding

    /// Whether the user has completed onboarding
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Whether onboarding should be shown (not completed and no API keys configured)
    var needsOnboarding: Bool {
        !hasCompletedOnboarding
    }

    var defaultModel: DefaultModel {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultModel),
                  let value = DefaultModel(rawValue: raw) else {
                return .openai  // Default to OpenAI
            }
            // Claude is "coming soon" in Settings; coerce any stored pick to the default.
            return value == .anthropic ? .openai : value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultModel) }
    }

    // MARK: - Appearance

    var appearance: Appearance {
        get {
            guard let raw = defaults.string(forKey: Keys.appearance),
                  let value = Appearance(rawValue: raw) else {
                return .light  // Default to light mode
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    /// Get the NSAppearance for the current setting
    var nsAppearance: NSAppearance? {
        switch appearance {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .system:
            return nil  // Use system default
        }
    }

    // MARK: - Diagnostics

    /// Whether to send diagnostic data (app version, request IDs, etc.)
    /// Defaults to true if not explicitly set
    var diagnosticsEnabled: Bool {
        get {
            // Default to true if not set
            if defaults.object(forKey: Keys.diagnosticsEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.diagnosticsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.diagnosticsEnabled) }
    }

    // MARK: - Editor Typography

    var editorFont: EditorFont {
        get {
            guard let raw = defaults.string(forKey: Keys.editorFont),
                  let value = EditorFont(rawValue: raw) else {
                return .systemSans
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.editorFont) }
    }

    var editorFontSize: Double {
        get {
            if defaults.object(forKey: Keys.editorFontSize) == nil {
                return 16.0
            }
            let value = defaults.double(forKey: Keys.editorFontSize)
            return min(max(value, 13.0), 24.0)
        }
        set { defaults.set(min(max(newValue, 13.0), 24.0), forKey: Keys.editorFontSize) }
    }

    var editorLineSpacing: Double {
        get {
            if defaults.object(forKey: Keys.editorLineSpacing) == nil {
                return 1.55
            }
            let value = defaults.double(forKey: Keys.editorLineSpacing)
            return min(max(value, 1.3), 2.0)
        }
        set { defaults.set(min(max(newValue, 1.3), 2.0), forKey: Keys.editorLineSpacing) }
    }

    // MARK: - Settings Dictionary (for bridge)

    /// Get all settings as a dictionary for sending to React
    func allSettings() -> [String: Any] {
        [
            "proxyOnlyMode": Self.proxyOnlyMode,
            "defaultModel": defaultModel.rawValue,
            "appearance": appearance.rawValue,
            "diagnosticsEnabled": diagnosticsEnabled,
            "editorFont": editorFont.rawValue,
            "editorFontSize": editorFontSize,
            "editorLineSpacing": editorLineSpacing
        ]
    }
}
