import Foundation

/// Protocol for AI service providers
/// Abstracts different LLM backends (OpenAI, Perplexity, etc.) behind a common interface
protocol LLMProvider {
    /// Unique identifier for this provider
    var id: String { get }

    /// Human-readable name for display
    var name: String { get }

    /// The specific model ID used by this provider (e.g., "gpt-4o", "sonar")
    var modelId: String { get }

    /// Whether the provider is properly configured (API key set, etc.)
    var isConfigured: Bool { get }

    /// Stream a completion request
    /// - Parameters:
    ///   - request: The LLM request parameters
    ///   - onModelSelected: Optional callback with resolved (provider, model) from proxy headers
    ///   - onChunk: Called for each streamed chunk of content
    ///   - onComplete: Called when streaming finishes
    ///   - onError: Called if an error occurs
    func stream(
        request: LLMRequest,
        onModelSelected: ((String, String) -> Void)?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async
}

/// Content part for multimodal messages
enum LLMContentPart {
    case text(String)
    case imageURL(String)  // URL to image (can be data URL or http URL)
}

/// A message in an LLM conversation
struct LLMMessage {
    var role: String
    var content: String
    var imageURLs: [String]  // Optional image URLs for vision models

    init(role: String, content: String, imageURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
    }

    /// Whether this message contains images
    var hasImages: Bool { !imageURLs.isEmpty }
}

/// Intent for proxy routing (matches proxy's expected schema)
struct LLMIntent {
    let type: String
    let confidence: Float
    let source: String

    /// Convert ClassificationResult to LLMIntent
    init(from result: ClassificationResult) {
        self.type = result.intent.rawValue
        self.confidence = result.confidence
        self.source = "mlx"
    }

    /// Convert to dictionary for JSON serialization
    func toDictionary() -> [String: Any] {
        return [
            "type": type,
            "confidence": confidence,
            "source": source
        ]
    }
}

/// A standardized request to an LLM provider
struct LLMRequest {
    /// System prompt for the model
    var systemPrompt: String

    /// Conversation messages with optional image support
    var messages: [LLMMessage]

    /// Temperature for response randomness (0.0 - 1.0)
    var temperature: Double

    /// Maximum tokens to generate (nil for provider default)
    var maxTokens: Int?

    /// Optional intent for proxy routing (set by orchestrator when using smart routing)
    var intent: LLMIntent?

    init(
        systemPrompt: String,
        messages: [LLMMessage],
        temperature: Double = 0.7,
        maxTokens: Int? = nil,
        intent: LLMIntent? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.intent = intent
    }

    /// Convenience initializer for text-only messages
    init(
        systemPrompt: String,
        textMessages: [(role: String, content: String)],
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = textMessages.map { LLMMessage(role: $0.role, content: $0.content) }
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Whether any message in the request contains images
    var hasImages: Bool {
        messages.contains { $0.hasImages }
    }

    // MARK: - Token Budgeting

    /// Approximate number of tokens (~4 chars per token for English)
    private static let charsPerToken: Double = 4.0

    /// Approximate tokens per image (OpenAI vision uses ~85 tokens for low-detail, up to 1105 for high-detail)
    private static let tokensPerImage: Int = 500  // Conservative estimate

    /// Estimate token count for a string
    static func estimateTokens(_ text: String) -> Int {
        Int(ceil(Double(text.count) / charsPerToken))
    }

    /// Estimate token count for a message (including images)
    static func estimateTokens(_ message: LLMMessage) -> Int {
        var tokens = estimateTokens(message.content)
        tokens += message.imageURLs.count * tokensPerImage
        tokens += 4  // Message overhead
        return tokens
    }

    /// Total estimated tokens in this request
    var estimatedTokenCount: Int {
        var total = LLMRequest.estimateTokens(systemPrompt)
        for message in messages {
            total += LLMRequest.estimateTokens(message)
        }
        return total
    }

    /// Truncate request to fit within a token budget by removing oldest messages
    /// Keeps system prompt, first context message (if any), and most recent messages
    /// - Parameter budget: Maximum token count (default 100,000 for GPT-4o-mini safety margin)
    /// - Returns: A new request with truncated messages if needed
    func truncated(toTokenBudget budget: Int = 100_000) -> LLMRequest {
        let systemTokens = LLMRequest.estimateTokens(systemPrompt)
        var availableBudget = budget - systemTokens - (maxTokens ?? 2048)

        guard availableBudget > 0 else {
            // Not enough room even for system prompt, return with no messages
            return LLMRequest(
                systemPrompt: systemPrompt,
                messages: [],
                temperature: temperature,
                maxTokens: maxTokens,
                intent: intent
            )
        }

        // Always keep the last message (current query)
        guard let lastMessage = messages.last else { return self }
        let lastTokens = LLMRequest.estimateTokens(lastMessage)
        availableBudget -= lastTokens

        // Build messages from most recent to oldest, stopping when we run out of budget
        var keptMessages: [LLMMessage] = []
        for message in messages.dropLast().reversed() {
            let messageTokens = LLMRequest.estimateTokens(message)
            if availableBudget >= messageTokens {
                keptMessages.insert(message, at: 0)
                availableBudget -= messageTokens
            } else {
                // Out of budget, stop adding older messages
                break
            }
        }

        // Add back the last message
        keptMessages.append(lastMessage)

        return LLMRequest(
            systemPrompt: systemPrompt,
            messages: keptMessages,
            temperature: temperature,
            maxTokens: maxTokens,
            intent: intent
        )
    }
}

/// Errors that can occur in LLM providers
enum LLMProviderError: LocalizedError {
    case notConfigured(String)
    case invalidRequest
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return "\(provider) API key not configured. Go to Settings to add your key."
        case .invalidRequest:
            return "Failed to build API request"
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}

// MARK: - Proxy Errors

/// Quota exceeded details from proxy
struct ProxyQuotaDetails {
    let scope: String           // "day" or "month"
    let limit: Int
    let used: Int
    let resetAt: String         // ISO8601 timestamp
}

/// Errors specific to proxy LLM requests
enum ProxyLLMError: LocalizedError {
    case unreachable                                // Network error
    case timeout(seconds: Int)                      // No response/first byte within timeout
    case invalidKey                                 // 401: key invalid/expired
    case keyBoundElsewhere(supportId: String?)      // 401: key bound to different device
    case rateLimited(retryAfter: Int?)              // 429: req/min exceeded
    case quotaExceeded(details: ProxyQuotaDetails)  // 429: token budget exceeded
    case validationError(String)                    // 400: bad request
    case upstreamError(requestId: String?, message: String)  // 502: LLM provider error
    case serverError(statusCode: Int, requestId: String?)    // 5xx: other server errors

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "AI unavailable. Check your connection."
        case .timeout(let seconds):
            return "AI request timed out after \(seconds)s. Please try again."
        case .invalidKey:
            return "Device key invalid or expired. Please re-enter in Settings."
        case .keyBoundElsewhere(let supportId):
            if let id = supportId {
                return "Key bound to another device. Contact support (ID: \(id))."
            }
            return "Key bound to another device. Contact support."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limit exceeded. Try again in \(seconds)s."
            }
            return "Rate limit exceeded. Try again in a moment."
        case .quotaExceeded(let details):
            let scopeLabel = details.scope == "day" ? "Daily" : "Monthly"
            return "\(scopeLabel) quota exceeded (\(details.used)/\(details.limit) tokens)."
        case .validationError(let message):
            return "Request error: \(message)"
        case .upstreamError(_, let message):
            return "AI provider error: \(message)"
        case .serverError(let code, _):
            return "Server error (\(code)). Please try again."
        }
    }

    /// Error code for bridge messaging
    var errorCode: String {
        switch self {
        case .unreachable: return "proxy_unreachable"
        case .timeout: return "proxy_timeout"
        case .invalidKey: return "invalid_key"
        case .keyBoundElsewhere: return "key_bound_elsewhere"
        case .rateLimited: return "rate_limited"
        case .quotaExceeded: return "quota_exceeded"
        case .validationError: return "validation_error"
        case .upstreamError: return "upstream_error"
        case .serverError: return "server_error"
        }
    }

    /// Request ID if available (for support reference)
    var requestId: String? {
        switch self {
        case .upstreamError(let id, _), .serverError(_, let id):
            return id
        default:
            return nil
        }
    }

    /// Whether this error should trigger key invalidation
    var shouldInvalidateKey: Bool {
        switch self {
        case .invalidKey, .keyBoundElsewhere:
            return true
        default:
            return false
        }
    }
}
