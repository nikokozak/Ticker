import Foundation

/// Intent types that the classifier can identify
enum QueryIntent: String, CaseIterable {
    /// Needs current/real-time information (web search via Perplexity)
    case search
    /// General knowledge question (GPT)
    case knowledge
    /// Expand on existing content
    case expand
    /// Summarize content
    case summarize
    /// Rewrite/rephrase content
    case rewrite
    /// Extract key points
    case extract
    /// Unclear or needs more context
    case ambiguous

    var description: String {
        switch self {
        case .search: return "Real-time search query"
        case .knowledge: return "Knowledge-based question"
        case .expand: return "Expand on content"
        case .summarize: return "Summarize content"
        case .rewrite: return "Rewrite content"
        case .extract: return "Extract key points"
        case .ambiguous: return "Unclear intent"
        }
    }
}

/// Result of query classification
struct ClassificationResult {
    let intent: QueryIntent
    let confidence: Float
    let reasoning: String?
}

/// Protocol for query classification backends
protocol QueryClassifier {
    /// Classify a user query into an intent
    func classify(query: String) async throws -> ClassificationResult

    /// Whether the classifier is ready to use
    var isReady: Bool { get }

    /// Whether the classifier is currently loading
    var isLoading: Bool { get }

    /// Any error that occurred during loading
    var loadError: Error? { get }

    /// Load/initialize the classifier if needed
    func prepare() async throws
}

/// Deterministic search-vs-knowledge gate.
///
/// This replaced an MLX Qwen2.5-0.5B classifier: live testing showed the model
/// answering queries instead of classifying, drifting off-vocabulary
/// ("explore", "apply"), confidently misclassifying ("rewrite" for a markets
/// question), and getting the keyword-less cases wrong anyway. Transform verbs
/// pass fixed prompts and skip classification, so the only live decision is
/// search vs knowledge — which keywords answer deterministically, with no
/// model download, RAM, or parse brittleness. The protocol seam stays for a
/// stronger local model later.
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private enum FMQueryKind: String {
    case search
    case knowledge
}

/// Apple Intelligence classifier: guided generation constrains decoding to the
/// enum above, so off-vocabulary drift is structurally impossible. Keyword
/// pre-pass keeps the obvious search queries deterministic and free.
@available(macOS 26.0, *)
struct FoundationModelClassifier: QueryClassifier {
    private let keyword = KeywordClassifier()

    let isLoading = false
    let loadError: Error? = nil
    var isReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func prepare() async throws {}

    func classify(query: String) async throws -> ClassificationResult {
        let keywordResult = try await keyword.classify(query: query)
        if keywordResult.intent == .search { return keywordResult }

        let session = LanguageModelSession(
            instructions: "Classify whether answering the query needs live, up-to-date information from the web (search) or can be answered from general knowledge (knowledge)."
        )
        let response = try await session.respond(to: "Query: \(query)", generating: FMQueryKind.self)
        let intent: QueryIntent = response.content == .search ? .search : .knowledge
        return ClassificationResult(intent: intent, confidence: 0.8, reasoning: "foundation-model")
    }
}
#endif

struct KeywordClassifier: QueryClassifier {
    // No bare "current": it misfires on physics/engineering queries
    // ("amplify current" is not current events).
    private static let searchKeywords = [
        "news", "weather", "today", "this morning", "yesterday", "tonight",
        "latest", "recent", "current events", "what happened", "stock price",
        "score", "election", "breaking"
    ]

    let isReady = true
    let isLoading = false
    let loadError: Error? = nil

    func prepare() async throws {}

    func classify(query: String) async throws -> ClassificationResult {
        let queryLower = query.lowercased()
        if Self.searchKeywords.contains(where: queryLower.contains) {
            return ClassificationResult(intent: .search, confidence: 0.9, reasoning: "keyword")
        }
        return ClassificationResult(intent: .knowledge, confidence: 0.6, reasoning: "default")
    }
}
