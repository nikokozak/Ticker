import Foundation

/// Debug-only logging helper.
///
/// Policy:
/// - Do not log user content/prompts in Release builds.
/// - Prefer user-visible errors (toasts/alerts) + support bundle, not console logs.
enum DebugLog {
    static func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    static func errorSummary(_ error: Error) -> String {
#if DEBUG
        let nsError = error as NSError
        return "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code)"
#else
        return ""
#endif
    }
}
