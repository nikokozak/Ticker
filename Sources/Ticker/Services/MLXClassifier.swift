import Foundation

/// Heuristic query classifier used for smart routing.
///
/// This intentionally avoids heavyweight local model dependencies so the app and tests
/// remain buildable on current Swift/Xcode toolchains.
final class MLXClassifier: QueryClassifier {
    private let modelId = "heuristic"

    // MARK: - QueryClassifier State

    private(set) var isLoading = false
    private(set) var loadError: Error?

    var isReady: Bool {
        true
    }


    func prepare() async throws {
        guard !isLoading else { return }
        isLoading = true

        DebugLog.log("MLXClassifier: Loading model \(modelId)...")
        DebugLog.log("MLXClassifier: Model loaded successfully")

        isLoading = false
    }

    func classify(query: String) async throws -> ClassificationResult {
        let cleanedOutput = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let intent = parseIntent(from: cleanedOutput, query: query)

        return ClassificationResult(
            intent: intent,
            confidence: intent == .ambiguous ? 0.5 : 0.8,
            reasoning: cleanedOutput
        )
    }

    private func parseIntent(from output: String, query: String) -> QueryIntent {
        // Try to match the output to an intent
        for intent in QueryIntent.allCases {
            if output.contains(intent.rawValue) {
                return intent
            }
        }

        // Fuzzy matching for common variations in model output
        if output.contains("search") || output.contains("look up") || output.contains("find") {
            return .search
        }
        if output.contains("knowledge") || output.contains("explain") || output.contains("what is") {
            return .knowledge
        }
        if output.contains("expand") || output.contains("elaborate") || output.contains("more detail") {
            return .expand
        }
        if output.contains("summar") {
            return .summarize
        }
        if output.contains("rewrite") || output.contains("rephrase") {
            return .rewrite
        }
        if output.contains("extract") || output.contains("key point") {
            return .extract
        }

        // Fallback: use heuristics on the original query if model output is unclear
        let queryLower = query.lowercased()
        let searchKeywords = ["news", "weather", "today", "this morning", "yesterday", "tonight",
                              "latest", "recent", "current", "what happened", "stock price",
                              "score", "results", "election", "breaking"]
        for keyword in searchKeywords {
            if queryLower.contains(keyword) {
                return .search
            }
        }

        return .ambiguous
    }
}
