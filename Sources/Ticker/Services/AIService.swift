import Foundation

/// Handles AI interactions with OpenAI API
/// @deprecated For alpha, all LLM traffic routes through Ticker Proxy.
/// This service is kept as a fallback for development/testing with local API keys.
/// In production, vendorKeysEnabled = false so this service reports isConfigured = false.
final class AIService: LLMProvider {
    private let settings: SettingsService
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let textModel = "gpt-4o-mini"
    private let visionModel = "gpt-4o"  // Use full gpt-4o for vision (better quality)

    // MARK: - LLMProvider

    let id = "openai"
    let name = "OpenAI"
    var modelId: String { textModel }

    init(settings: SettingsService = .shared) {
        self.settings = settings
    }

    /// Get API key from settings or environment
    private var apiKey: String? {
        // In proxy-only mode, never return an API key
        guard !SettingsService.proxyOnlyMode else { return nil }
        return settings.openaiAPIKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
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
        // Legacy vendor service - onModelSelected not used (would just report our own modelId)
        guard let apiKey else {
            onError(LLMProviderError.notConfigured(name))
            return
        }

        // Use vision model if request contains images
        let modelToUse = request.hasImages ? visionModel : textModel

        // Build messages array with multimodal support
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.systemPrompt]
        ]

        for msg in request.messages {
            if msg.hasImages {
                // Multimodal message with images
                var content: [[String: Any]] = [
                    ["type": "text", "text": msg.content]
                ]
                for imageURL in msg.imageURLs {
                    content.append([
                        "type": "image_url",
                        "image_url": ["url": imageURL, "detail": "auto"]
                    ])
                }
                messages.append(["role": msg.role, "content": content])
            } else {
                // Text-only message
                messages.append(["role": msg.role, "content": msg.content])
            }
        }

        var requestBody: [String: Any] = [
            "model": modelToUse,
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

        let delegate = StreamingDelegate(onChunk: onChunk, onComplete: onComplete, onError: onError)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: urlRequest)
        task.resume()
    }

    // MARK: - Restatement

    /// Generate a heading/title form of the user's input (non-streaming)
    func generateRestatement(
        for input: String,
        completion: @escaping (String?) -> Void
    ) {
        guard let apiKey else {
            completion(nil)
            return
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Prompts.restatement],
            ["role": "user", "content": input]
        ]

        let requestBody: [String: Any] = [
            "model": textModel,
            "messages": messages,
            "max_tokens": 50,
            "temperature": 0.3
        ]

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { data, response, error in
            // Validate HTTP status code
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (trimmed == "NONE" || trimmed.isEmpty) ? nil : trimmed

            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - Modifier Label

    /// Generate a short label for a modifier prompt (async)
    func generateLabel(for prompt: String) async throws -> String {
        guard let apiKey else {
            throw AIError.notConfigured
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Prompts.modifierLabel],
            ["role": "user", "content": prompt]
        ]

        let requestBody: [String: Any] = [
            "model": textModel,
            "messages": messages,
            "max_tokens": 20,
            "temperature": 0.3
        ]

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw AIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Apply Modifier

    /// Apply a modifier to content with streaming
    func applyModifier(
        currentContent: String,
        modifierPrompt: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard let apiKey else {
            onError(AIError.notConfigured)
            return
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Prompts.applyModifier],
            ["role": "user", "content": "Content to transform:\n\n\(currentContent)\n\n---\n\nInstruction: \(modifierPrompt)"]
        ]

        let requestBody: [String: Any] = [
            "model": textModel,
            "messages": messages,
            "stream": true,
            "max_tokens": 2048
        ]

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            onError(AIError.invalidRequest)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let delegate = StreamingDelegate(onChunk: onChunk, onComplete: onComplete, onError: onError)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        let task = session.dataTask(with: request)
        task.resume()
    }

}

// MARK: - Streaming Delegate

private class StreamingDelegate: NSObject, URLSessionDataDelegate {
    private let onChunk: (String) -> Void
    private let onComplete: () -> Void
    private let onError: (Error) -> Void
    private var buffer = ""
    private var hasCompleted = false  // Prevent duplicate completion calls

    init(
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError
    }

    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        onComplete()
    }

    private func fail(_ error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        onError(error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        buffer += text

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])

            if line.hasPrefix("data: ") {
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" {
                    complete()
                    return
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    onChunk(content)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fail(error)
        } else {
            complete()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            onError(AIError.apiError(httpResponse.statusCode, "API request failed"))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case notConfigured
    case invalidRequest
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenAI API key not configured. Go to Settings to add your key."
        case .invalidRequest:
            return "Failed to build API request"
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}
