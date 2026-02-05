import Foundation
import AppKit

/// Settings storage with Keychain-backed API keys and UserDefaults for preferences
final class SettingsService {
    static let shared = SettingsService()

    private let defaults: UserDefaults
    private let keychain = KeychainService.shared
    /// Alpha posture: all AI goes through `ticker-proxy`, so vendor API keys are disabled.
    /// This prevents Keychain access prompts in signed Release builds.
    private static let vendorKeysEnabled = false

    /// Proxy-only mode: all LLM and embedding calls must go through Ticker Proxy.
    /// When true, local vendor API calls (OpenAI, Anthropic, Perplexity) are disabled at runtime.
    /// This includes EmbeddingService (RAG is disabled for alpha).
    static let proxyOnlyMode = true

    // UserDefaults keys (non-sensitive settings)
    private enum Keys {
        static let smartRoutingEnabled = "smart_routing_enabled"
        static let defaultModel = "default_model"
        static let appearance = "appearance"
        static let hasCompletedKeychainMigration = "has_completed_keychain_migration"
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let diagnosticsEnabled = "diagnostics_enabled"
        // Legacy keys (for migration)
        static let legacyOpenaiAPIKey = "openai_api_key"
        static let legacyAnthropicAPIKey = "anthropic_api_key"
        static let legacyPerplexityAPIKey = "perplexity_api_key"
    }

    // Keychain keys (sensitive data)
    private enum KeychainKeys {
        static let openaiAPIKey = "openai_api_key"
        static let anthropicAPIKey = "anthropic_api_key"
        static let perplexityAPIKey = "perplexity_api_key"
    }

    enum Appearance: String {
        case light = "light"
        case dark = "dark"
        case system = "system"
    }

    enum DefaultModel: String {
        case openai = "openai"
        case anthropic = "anthropic"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Alpha: vendor keys disabled; avoid touching Keychain unless explicitly re-enabled.
        if Self.vendorKeysEnabled {
            migrateKeysToKeychain()
        }
    }

    // MARK: - API Keys (Keychain-backed)

    var openaiAPIKey: String? {
        get { Self.vendorKeysEnabled ? keychain.get(key: KeychainKeys.openaiAPIKey) : nil }
        set {
            guard Self.vendorKeysEnabled else { return }
            if let value = newValue, !value.isEmpty {
                try? keychain.save(key: KeychainKeys.openaiAPIKey, value: value)
            } else {
                keychain.delete(key: KeychainKeys.openaiAPIKey)
            }
        }
    }

    var anthropicAPIKey: String? {
        get { Self.vendorKeysEnabled ? keychain.get(key: KeychainKeys.anthropicAPIKey) : nil }
        set {
            guard Self.vendorKeysEnabled else { return }
            if let value = newValue, !value.isEmpty {
                try? keychain.save(key: KeychainKeys.anthropicAPIKey, value: value)
            } else {
                keychain.delete(key: KeychainKeys.anthropicAPIKey)
            }
        }
    }

    var perplexityAPIKey: String? {
        get { Self.vendorKeysEnabled ? keychain.get(key: KeychainKeys.perplexityAPIKey) : nil }
        set {
            guard Self.vendorKeysEnabled else { return }
            if let value = newValue, !value.isEmpty {
                try? keychain.save(key: KeychainKeys.perplexityAPIKey, value: value)
            } else {
                keychain.delete(key: KeychainKeys.perplexityAPIKey)
            }
        }
    }

    // MARK: - Keychain Migration

    private func migrateKeysToKeychain() {
        // Skip if already migrated
        guard !defaults.bool(forKey: Keys.hasCompletedKeychainMigration) else { return }

        print("[Settings] Migrating API keys from UserDefaults to Keychain...")

        // Migrate OpenAI key
        if let oldKey = defaults.string(forKey: Keys.legacyOpenaiAPIKey), !oldKey.isEmpty {
            if keychain.get(key: KeychainKeys.openaiAPIKey) == nil {
                try? keychain.save(key: KeychainKeys.openaiAPIKey, value: oldKey)
                print("[Settings] Migrated OpenAI key to Keychain")
            }
            defaults.removeObject(forKey: Keys.legacyOpenaiAPIKey)
        }

        // Migrate Anthropic key
        if let oldKey = defaults.string(forKey: Keys.legacyAnthropicAPIKey), !oldKey.isEmpty {
            if keychain.get(key: KeychainKeys.anthropicAPIKey) == nil {
                try? keychain.save(key: KeychainKeys.anthropicAPIKey, value: oldKey)
                print("[Settings] Migrated Anthropic key to Keychain")
            }
            defaults.removeObject(forKey: Keys.legacyAnthropicAPIKey)
        }

        // Migrate Perplexity key
        if let oldKey = defaults.string(forKey: Keys.legacyPerplexityAPIKey), !oldKey.isEmpty {
            if keychain.get(key: KeychainKeys.perplexityAPIKey) == nil {
                try? keychain.save(key: KeychainKeys.perplexityAPIKey, value: oldKey)
                print("[Settings] Migrated Perplexity key to Keychain")
            }
            defaults.removeObject(forKey: Keys.legacyPerplexityAPIKey)
        }

        defaults.set(true, forKey: Keys.hasCompletedKeychainMigration)
        print("[Settings] Keychain migration complete")
    }

    /// Check if the OpenAI API key is configured
    var isOpenAIConfigured: Bool {
        guard let key = openaiAPIKey else { return false }
        return !key.isEmpty
    }

    /// Check if the Anthropic API key is configured
    var isAnthropicConfigured: Bool {
        guard let key = anthropicAPIKey else { return false }
        return !key.isEmpty
    }

    /// Check if the Perplexity API key is configured
    var isPerplexityConfigured: Bool {
        guard let key = perplexityAPIKey else { return false }
        return !key.isEmpty
    }

    /// Legacy alias for backward compatibility
    var isAPIKeyConfigured: Bool {
        isOpenAIConfigured
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

    // MARK: - Routing Settings

    /// Whether to use MLX classifier for smart model routing.
    /// Defaults to true if not explicitly set (alpha posture: smart routing ON by default).
    var smartRoutingEnabled: Bool {
        get {
            // Default to true if not set
            if defaults.object(forKey: Keys.smartRoutingEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.smartRoutingEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.smartRoutingEnabled) }
    }

    var defaultModel: DefaultModel {
        get {
            guard let raw = defaults.string(forKey: Keys.defaultModel),
                  let value = DefaultModel(rawValue: raw) else {
                return .openai  // Default to OpenAI
            }
            return value
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

    // MARK: - Settings Dictionary (for bridge)

    /// Get all settings as a dictionary for sending to React
    func allSettings() -> [String: Any] {
        [
            "proxyOnlyMode": Self.proxyOnlyMode,
            "smartRoutingEnabled": smartRoutingEnabled,
            "defaultModel": defaultModel.rawValue,
            "appearance": appearance.rawValue,
            "diagnosticsEnabled": diagnosticsEnabled
        ]
    }

    /// Mask an API key for display (show first 7 and last 4 chars)
    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 12 else { return "••••••••" }
        let prefix = String(key.prefix(7))
        let suffix = String(key.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }
}
