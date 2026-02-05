import Foundation
import MLXLLM
import MLXLMCommon

/// MLX-based local query classifier using a small LLM
final class MLXClassifier: QueryClassifier {
    private var container: ModelContainer?
    private let modelId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    // MARK: - QueryClassifier State

    private(set) var isLoading = false
    private(set) var loadError: Error?

    var isReady: Bool {
        container != nil
    }


    func prepare() async throws {
        guard container == nil, !isLoading else { return }
        isLoading = true

        do {
            DebugLog.log("MLXClassifier: Loading model \(modelId)...")
            let loadedContainer = try await loadModelContainer(id: modelId)
            self.container = loadedContainer
            DebugLog.log("MLXClassifier: Model loaded successfully")
        } catch {
            loadError = error
            DebugLog.log("MLXClassifier: Failed to load model (\(DebugLog.errorSummary(error)))")
            throw error
        }

        isLoading = false
    }

    func classify(query: String) async throws -> ClassificationResult {
        guard let container else {
            throw ClassifierError.modelNotLoaded
        }

        let session = ChatSession(
            container,
            instructions: Prompts.classifier,
            generateParameters: GenerateParameters(
                maxTokens: 10,
                temperature: 0.1  // Low temperature for deterministic classification
            )
        )

        let output = try await session.respond(to: query)
        let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let intent = parseIntent(from: cleanedOutput, query: query)

        return ClassificationResult(
            intent: intent,
            confidence: intent == .ambiguous ? 0.5 : 0.9,
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

enum ClassifierError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Classification model not loaded"
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        }
    }
}
