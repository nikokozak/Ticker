import Foundation

/// Service for Anthropic API calls (Claude models)
/// @deprecated For alpha, all LLM traffic routes through Ticker Proxy.
/// This service is kept as a fallback for development/testing with local API keys.
/// In production, vendorKeysEnabled = false so this service reports isConfigured = false.
final class AnthropicService: LLMProvider {
    private let settings: SettingsService
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let textModel = "claude-sonnet-4-20250514"
    private let visionModel = "claude-sonnet-4-20250514"  // Claude supports vision natively

    // MARK: - LLMProvider

    let id = "anthropic"
    let name = "Anthropic"
    var modelId: String { textModel }

    init(settings: SettingsService = .shared) {
        self.settings = settings
    }

    /// Get API key from settings or environment
    private var apiKey: String? {
        // In proxy-only mode, never return an API key
        guard !SettingsService.proxyOnlyMode else { return nil }
        return settings.anthropicAPIKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
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

        // Use vision model if request contains images
        let modelToUse = request.hasImages ? visionModel : textModel

        // Build messages array with multimodal support
        // Anthropic uses a different format - system is a top-level parameter
        var messages: [[String: Any]] = []

        for msg in request.messages {
            if msg.hasImages {
                // Multimodal message with images
                var content: [[String: Any]] = [
                    ["type": "text", "text": msg.content]
                ]
                for imageURL in msg.imageURLs {
                    // Anthropic expects base64 images differently
                    if imageURL.starts(with: "data:") {
                        // Parse data URL: data:image/png;base64,<data>
                        if let (mediaType, base64Data) = parseDataURL(imageURL) {
                            content.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": base64Data
                                ]
                            ])
                        }
                    } else {
                        // URL-based image
                        content.append([
                            "type": "image",
                            "source": [
                                "type": "url",
                                "url": imageURL
                            ]
                        ])
                    }
                }
                messages.append(["role": msg.role, "content": content])
            } else {
                // Text-only message
                messages.append(["role": msg.role, "content": msg.content])
            }
        }

        // Anthropic requires alternating user/assistant messages
        // Merge consecutive messages of the same role
        messages = mergeConsecutiveMessages(messages)

        var requestBody: [String: Any] = [
            "model": modelToUse,
            "messages": messages,
            "system": request.systemPrompt,
            "stream": true,
            "max_tokens": request.maxTokens ?? 2048
        ]

        // Add temperature if not default
        if request.temperature != 1.0 {
            requestBody["temperature"] = request.temperature
        }

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            onError(LLMProviderError.invalidRequest)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
                // Anthropic uses Server-Sent Events format
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))

                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                        // Handle different event types
                        if let eventType = json["type"] as? String {
                            switch eventType {
                            case "content_block_delta":
                                // Extract text from delta
                                if let delta = json["delta"] as? [String: Any],
                                   let text = delta["text"] as? String {
                                    await MainActor.run { onChunk(text) }
                                }

                            case "message_stop":
                                await MainActor.run { onComplete() }
                                return

                            case "error":
                                if let error = json["error"] as? [String: Any],
                                   let message = error["message"] as? String {
                                    await MainActor.run {
                                        onError(LLMProviderError.apiError(0, message))
                                    }
                                    return
                                }

                            default:
                                // Ignore other event types (message_start, content_block_start, etc.)
                                break
                            }
                        }
                    }
                }
            }

            await MainActor.run { onComplete() }

        } catch {
            await MainActor.run { onError(error) }
        }
    }

    // MARK: - Private Helpers

    /// Parse a data URL into media type and base64 data
    private func parseDataURL(_ dataURL: String) -> (mediaType: String, data: String)? {
        // Format: data:image/png;base64,<data>
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metaPart = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<commaIndex]
        let dataPart = String(dataURL[dataURL.index(after: commaIndex)...])

        // Extract media type (before ;base64)
        let mediaType: String
        if let semicolonIndex = metaPart.firstIndex(of: ";") {
            mediaType = String(metaPart[..<semicolonIndex])
        } else {
            mediaType = String(metaPart)
        }

        return (mediaType, dataPart)
    }

    /// Merge consecutive messages of the same role (required by Anthropic API)
    private func mergeConsecutiveMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }

            if let lastMsg = result.last,
               let lastRole = lastMsg["role"] as? String,
               lastRole == role {
                // Merge with previous message of same role
                var merged = lastMsg

                // Handle different content types
                if let lastContent = lastMsg["content"] as? String,
                   let newContent = msg["content"] as? String {
                    // Both are simple strings
                    merged["content"] = lastContent + "\n\n" + newContent
                } else if let lastContent = lastMsg["content"] as? [[String: Any]],
                          let newContent = msg["content"] as? [[String: Any]] {
                    // Both are content arrays
                    merged["content"] = lastContent + newContent
                } else if let lastContent = lastMsg["content"] as? String,
                          let newContent = msg["content"] as? [[String: Any]] {
                    // Last is string, new is array - convert and merge
                    var contentArray: [[String: Any]] = [["type": "text", "text": lastContent]]
                    contentArray.append(contentsOf: newContent)
                    merged["content"] = contentArray
                } else if let lastContent = lastMsg["content"] as? [[String: Any]],
                          let newContent = msg["content"] as? String {
                    // Last is array, new is string - append text
                    var contentArray = lastContent
                    contentArray.append(["type": "text", "text": newContent])
                    merged["content"] = contentArray
                }

                result[result.count - 1] = merged
            } else {
                result.append(msg)
            }
        }

        return result
    }
}
