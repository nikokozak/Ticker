import Foundation

/// LLM provider that routes requests through the Ticker proxy
/// Used when device key is active; handles proxy-specific error codes
final class ProxyLLMService: LLMProvider {
    private let deviceKeyService: DeviceKeyService

    // MARK: - LLMProvider

    let id = "proxy"
    let name = "Ticker Proxy"
    var modelId: String { "proxy" }  // Actual model determined by request

    init(deviceKeyService: DeviceKeyService = .shared) {
        self.deviceKeyService = deviceKeyService
    }

    /// Proxy base URL - matches DeviceKeyService
    private var proxyBaseURL: String {
        if let envURL = ProcessInfo.processInfo.environment["TICKER_PROXY_URL"], !envURL.isEmpty {
            return envURL
        }
        if let defaultsURL = UserDefaults.standard.string(forKey: "TickerProxyURL"), !defaultsURL.isEmpty {
            return defaultsURL
        }
        return "https://ticker-proxy.fly.dev"
    }

    var isConfigured: Bool {
        // Proxy service is always "configured" from a protocol perspective.
        // The actual proxy mode check happens in AIOrchestrator.route() which
        // verifies DeviceKeyService.currentState.isUsable before selecting this provider.
        true
    }

    /// Stream a completion request through the proxy
    func stream(
        request: LLMRequest,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        // Get credentials from device key service
        let headers = await deviceKeyService.getProxyHeaders()
        guard let headers else {
            await MainActor.run {
                onError(ProxyLLMError.invalidKey)
            }
            return
        }

        // Build request URL
        guard let url = URL(string: "\(proxyBaseURL)/v1/llm/request") else {
            await MainActor.run {
                onError(ProxyLLMError.validationError("Invalid proxy URL"))
            }
            return
        }

        // Build request body in proxy format
        let messages = buildProxyMessages(from: request)
        let requestBody: [String: Any] = [
            "model": determineModel(for: request),
            "messages": messages,
            "provider": determineProvider(for: request),
            "stream": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            await MainActor.run {
                onError(ProxyLLMError.validationError("Failed to encode request"))
            }
            return
        }

        // Build URL request
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add functional headers (auth + device ID)
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Add diagnostic headers (conditional on user preference)
        let requestId = await deviceKeyService.applyDiagnosticsHeaders(to: &urlRequest)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    onError(ProxyLLMError.validationError("Invalid response"))
                }
                return
            }

            // Get response request ID (prefer server's, fall back to what we sent)
            let responseRequestId = httpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? requestId

            // Record request ID if available (for support bundle)
            if let id = responseRequestId {
                await deviceKeyService.recordRequestId(id, endpoint: "llm")
            }

            // Handle non-200 responses
            if httpResponse.statusCode != 200 {
                // Extract Retry-After header if present (for rate limits)
                let retryAfterHeader: Int?
                if let retryAfterString = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                    retryAfterHeader = Int(retryAfterString)
                } else {
                    retryAfterHeader = nil
                }

                let error = await parseErrorResponse(
                    bytes: bytes,
                    statusCode: httpResponse.statusCode,
                    requestId: responseRequestId ?? "unknown",
                    retryAfterHeader: retryAfterHeader
                )

                // Invalidate key on auth errors
                if error.shouldInvalidateKey {
                    await deviceKeyService.clearProxyDeviceKey()
                }

                await MainActor.run { onError(error) }
                return
            }

            // Stream SSE events
            // Proxy format: "event: <type>\ndata: <json>\n\n"
            var currentEventType: String?
            var currentDataLine: String?

            for try await line in bytes.lines {
                if line.hasPrefix("event: ") {
                    // New event type
                    currentEventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    // Data payload
                    currentDataLine = String(line.dropFirst(6))
                } else if line.isEmpty {
                    // Blank line = dispatch the event
                    if let eventType = currentEventType, let dataLine = currentDataLine {
                        await handleSSEEvent(
                            eventType: eventType,
                            dataLine: dataLine,
                            requestId: responseRequestId ?? "unknown",
                            onChunk: onChunk,
                            onComplete: onComplete,
                            onError: onError
                        )

                        // Check if we should stop
                        if eventType == "done" || eventType == "error" {
                            return
                        }
                    }
                    currentEventType = nil
                    currentDataLine = nil
                }
            }

            // Stream ended without done event
            await MainActor.run { onComplete() }

        } catch _ as URLError {
            await MainActor.run {
                onError(ProxyLLMError.unreachable)
            }
        } catch {
            await MainActor.run {
                onError(ProxyLLMError.unreachable)
            }
        }
    }

    // MARK: - Message Building

    /// Convert LLMRequest messages to proxy format
    private func buildProxyMessages(from request: LLMRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.systemPrompt]
        ]

        for msg in request.messages {
            if msg.hasImages {
                // Multimodal message
                var content: [[String: Any]] = [
                    ["type": "text", "text": msg.content]
                ]

                for imageURL in msg.imageURLs {
                    if imageURL.starts(with: "data:") {
                        // Parse data URL and convert to proxy format
                        if let (mediaType, base64Data) = parseDataURL(imageURL) {
                            content.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "data": base64Data,
                                    "media_type": mediaType
                                ]
                            ])
                        }
                    } else {
                        // Alpha: proxy only supports base64 images
                        // URL-based images (ticker-asset://, file://, etc.) are dropped
                        DebugLog.log("[ProxyLLMService] Dropping non-base64 image URL (not supported in alpha)")
                    }
                }

                messages.append(["role": msg.role, "content": content])
            } else {
                // Text-only message
                messages.append(["role": msg.role, "content": msg.content])
            }
        }

        return messages
    }

    /// Parse a data URL into media type and base64 data
    private func parseDataURL(_ dataURL: String) -> (mediaType: String, data: String)? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metaPart = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<commaIndex]
        let dataPart = String(dataURL[dataURL.index(after: commaIndex)...])

        let mediaType: String
        if let semicolonIndex = metaPart.firstIndex(of: ";") {
            mediaType = String(metaPart[..<semicolonIndex])
        } else {
            mediaType = String(metaPart)
        }

        return (mediaType, dataPart)
    }

    // MARK: - Model/Provider Selection

    // Model IDs (mirroring AIService and AnthropicService)
    private static let openaiTextModel = "gpt-4o-mini"
    private static let openaiVisionModel = "gpt-4o"
    private static let anthropicTextModel = "claude-sonnet-4-20250514"
    private static let anthropicVisionModel = "claude-sonnet-4-20250514"

    /// Determine which model to request based on settings and request type
    private func determineModel(for request: LLMRequest) -> String {
        let defaultProvider = SettingsService.shared.defaultModel

        switch defaultProvider {
        case .openai:
            return request.hasImages ? Self.openaiVisionModel : Self.openaiTextModel
        case .anthropic:
            return request.hasImages ? Self.anthropicVisionModel : Self.anthropicTextModel
        }
    }

    /// Determine which provider to use based on settings
    private func determineProvider(for request: LLMRequest) -> String {
        switch SettingsService.shared.defaultModel {
        case .openai:
            return "openai"
        case .anthropic:
            return "anthropic"
        }
    }

    // MARK: - SSE Event Handling

    /// Handle a single SSE event
    private func handleSSEEvent(
        eventType: String,
        dataLine: String,
        requestId: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        guard let jsonData = dataLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        switch eventType {
        case "delta":
            // data: {"text": "..."}
            if let text = json["text"] as? String {
                await MainActor.run { onChunk(text) }
            }

        case "done":
            // data: {"usage": {...}}
            await MainActor.run { onComplete() }

        case "error":
            // data: {"error": {"code": "...", "message": "...", "details": {...}}}
            if let errorObj = json["error"] as? [String: Any] {
                let code = errorObj["code"] as? String ?? "unknown"
                let message = errorObj["message"] as? String ?? "Stream error"
                let details = errorObj["details"] as? [String: Any]
                let error = mapProxyError(
                    statusCode: 0,
                    code: code,
                    message: message,
                    details: details,
                    requestId: requestId
                )
                await MainActor.run { onError(error) }
            } else {
                await MainActor.run { onError(ProxyLLMError.validationError("Stream error")) }
            }

        default:
            break
        }
    }

    // MARK: - Error Handling

    /// Parse error response from proxy
    private func parseErrorResponse(
        bytes: URLSession.AsyncBytes,
        statusCode: Int,
        requestId: String,
        retryAfterHeader: Int?
    ) async -> ProxyLLMError {
        // Collect error body
        var errorBody = ""
        do {
            for try await line in bytes.lines {
                errorBody += line
            }
        } catch {
            // Ignore read errors, use what we have
        }

        // Try to parse structured error
        if let data = errorBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {

            let code = error["code"] as? String ?? "unknown"
            let message = error["message"] as? String ?? "Unknown error"
            var details = error["details"] as? [String: Any] ?? [:]

            // Inject Retry-After header value into details if present
            if let retryAfter = retryAfterHeader, details["retry_after"] == nil {
                details["retry_after"] = retryAfter
            }

            return mapProxyError(
                statusCode: statusCode,
                code: code,
                message: message,
                details: details,
                requestId: requestId
            )
        }

        // Fallback based on status code
        switch statusCode {
        case 401:
            return .invalidKey
        case 429:
            return .rateLimited(retryAfter: retryAfterHeader)
        case 502:
            return .upstreamError(requestId: requestId, message: errorBody.isEmpty ? "Provider error" : errorBody)
        default:
            return .serverError(statusCode: statusCode, requestId: requestId)
        }
    }

    /// Map proxy error response to ProxyLLMError
    private func mapProxyError(
        statusCode: Int,
        code: String,
        message: String,
        details: [String: Any]?,
        requestId: String
    ) -> ProxyLLMError {
        switch code {
        case "invalid_key":
            return .invalidKey

        case "key_revoked":
            return .invalidKey

        case "key_bound_elsewhere":
            let supportId = details?["support_id"] as? String
            return .keyBoundElsewhere(supportId: supportId)

        case "rate_limited", "rate_limit_exceeded":
            // Try to get retry_after from details, or compute from reset_at
            var retryAfter: Int? = details?["retry_after"] as? Int
            if retryAfter == nil, let resetAt = details?["reset_at"] as? String {
                // Parse ISO8601 and compute seconds until reset
                let formatter = ISO8601DateFormatter()
                if let resetDate = formatter.date(from: resetAt) {
                    let seconds = Int(resetDate.timeIntervalSinceNow)
                    if seconds > 0 {
                        retryAfter = seconds
                    }
                }
            }
            return .rateLimited(retryAfter: retryAfter)

        case "token_budget_exceeded":
            if let details = details {
                let quotaDetails = ProxyQuotaDetails(
                    scope: details["scope"] as? String ?? "day",
                    limit: details["limit"] as? Int ?? 0,
                    used: details["used"] as? Int ?? 0,
                    resetAt: details["reset_at"] as? String ?? ""
                )
                return .quotaExceeded(details: quotaDetails)
            }
            return .quotaExceeded(details: ProxyQuotaDetails(scope: "day", limit: 0, used: 0, resetAt: ""))

        case "validation_error":
            return .validationError(message)

        case "upstream_error":
            return .upstreamError(requestId: requestId, message: message)

        default:
            if statusCode >= 500 {
                return .serverError(statusCode: statusCode, requestId: requestId)
            }
            return .validationError(message)
        }
    }
}
