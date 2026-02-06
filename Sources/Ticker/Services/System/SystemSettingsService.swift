import AppKit

enum SystemSettingsService {
    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    @discardableResult
    static func openPrivacyPane(_ pane: PrivacyPane) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

