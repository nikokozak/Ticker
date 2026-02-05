import Foundation

/// Service for Perplexity API calls (real-time search)
/// @deprecated For alpha, all LLM traffic routes through Ticker Proxy.
/// This service is kept as a fallback for development/testing with local API keys.
/// In production, vendorKeysEnabled = false so this service reports isConfigured = false.
final class PerplexityService: LLMProvider {
    private let settings: SettingsService
    private let baseURL = "https://api.perplexity.ai/chat/completions"
    private let model = "sonar"  // Fast, good for search queries

    // MARK: - LLMProvider

    let id = "perplexity"
    let name = "Perplexity"
    var modelId: String { model }

    init(settings: SettingsService = .shared) {
        self.settings = settings
    }

    /// Get API key from settings or environment
    private var apiKey: String? {
        // In proxy-only mode, never return an API key
        guard !SettingsService.proxyOnlyMode else { return nil }
        return settings.perplexityAPIKey ?? ProcessInfo.processInfo.environment["PERPLEXITY_API_KEY"]
    }

    var isConfigured: Bool {
        // In proxy-only mode, always return false
        guard !SettingsService.proxyOnlyMode else { return false }
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    /// LLMProvider streaming implementation
    func stream(
        request: LLMRequest,
        onModelSelected: ((String, String) -> Void)? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        // Legacy vendor service - onModelSelected not used
        guard let apiKey else {
            onError(LLMProviderError.notConfigured(name))
            return
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": request.systemPrompt]
        ]

        // Perplexity requires alternating user/assistant messages
        // Merge consecutive messages of the same role
        // Note: Perplexity doesn't support images, so we only use text content
        for msg in request.messages {
            if let last = messages.last,
               last["role"] == msg.role,
               msg.role != "system" {
                // Merge with previous message of same role
                let merged = (last["content"] ?? "") + "\n\n" + msg.content
                messages[messages.count - 1]["content"] = merged
            } else {
                messages.append(["role": msg.role, "content": msg.content])
            }
        }

        // Perplexity requires the first non-system message to be a user/tool message.
        // If our history starts with an assistant response (e.g., the first cell is AI),
        // rewrite it into a user-context message to satisfy the alternation rule.
        if messages.count > 1, messages[1]["role"] == "assistant" {
            let assistantContent = messages[1]["content"] ?? ""
            messages[1]["role"] = "user"
            messages[1]["content"] = "Context from previous assistant response:\n\n\(assistantContent)"
        }

        // Normalize the message list after any rewrites to ensure user/assistant alternation.
        // This merges adjacent messages with the same role (non-system) so Perplexity accepts it.
        if messages.count > 2 {
            var normalized: [[String: String]] = [messages[0]]
            for i in 1..<messages.count {
                let current = messages[i]
                if let last = normalized.last,
                   last["role"] == current["role"],
                   current["role"] != "system" {
                    let merged = (last["content"] ?? "") + "\n\n" + (current["content"] ?? "")
                    normalized[normalized.count - 1]["content"] = merged
                } else {
                    normalized.append(current)
                }
            }
            messages = normalized
        }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": request.temperature
        ]
        if let maxTokens = request.maxTokens {
            requestBody["max_tokens"] = maxTokens
        }

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            onError(LLMProviderError.invalidRequest)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                onError(LLMProviderError.invalidRequest)
                return
            }

            if httpResponse.statusCode != 200 {
                // Collect error body for better error messages
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                }

                var errorMessage = "API request failed"
                if let data = errorBody.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    errorMessage = message
                } else if !errorBody.isEmpty {
                    errorMessage = errorBody
                }
                onError(LLMProviderError.apiError(httpResponse.statusCode, errorMessage))
                return
            }

            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }

                let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)

                if jsonString == "[DONE]" {
                    await MainActor.run { onComplete() }
                    return
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first {
                    // Perplexity can stream content under different keys depending on model/version.
                    let delta = firstChoice["delta"] as? [String: Any]
                    let message = firstChoice["message"] as? [String: Any]
                    let content =
                        (delta?["content"] as? String) ??
                        (message?["content"] as? String) ??
                        (firstChoice["text"] as? String)

                    if let content {
                        await MainActor.run { onChunk(content) }
                    }
                }
            }

            await MainActor.run { onComplete() }

        } catch {
            await MainActor.run { onError(error) }
        }
    }


    /// Search with streaming response (convenience wrapper around stream)
    func search(
        query: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        let request = LLMRequest(
            systemPrompt: Prompts.search,
            textMessages: [(role: "user", content: query)],
            temperature: 0.2,
            maxTokens: 1024
        )
        await stream(request: request, onChunk: onChunk, onComplete: onComplete, onError: onError)
    }
}
