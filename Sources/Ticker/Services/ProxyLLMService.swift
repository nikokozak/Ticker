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

    private var proxyDebugEnabled: Bool {
#if DEBUG
        // Default to ON in Debug builds so alpha QA always has proxy diagnostics in the terminal.
        return true
#else
        if let raw = ProcessInfo.processInfo.environment["TICKER_PROXY_DEBUG"], !raw.isEmpty {
            return raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
        }
        return UserDefaults.standard.bool(forKey: "TickerProxyDebug")
#endif
    }

    private func debugLog(_ message: String) {
        guard proxyDebugEnabled else { return }
        print("[ProxyLLMService] \(message)")
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
    /// - Parameters:
    ///   - request: The LLM request to stream
    ///   - onModelSelected: Called with resolved provider/model from proxy headers (before first chunk)
    ///   - onChunk: Called for each streamed text chunk
    ///   - onComplete: Called when stream completes successfully
    ///   - onError: Called if an error occurs
    func stream(
        request: LLMRequest,
        onModelSelected: ((String, String) -> Void)? = nil,
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
        let provider = determineProvider(for: request)
        var requestBody: [String: Any] = [
            "model": "default",  // Let proxy resolve model based on provider + vision
            "messages": messages,
            "provider": provider,
            "stream": true
        ]

        // Include intent if available (for smart routing on proxy side)
        if let intent = request.intent {
            requestBody["intent"] = intent.toDictionary()
        }

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
        // Avoid hanging indefinitely while still allowing long-running streams.
        // This acts as an "idle" timeout (no bytes transferred) rather than a strict overall cap.
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Proxy API pipeline expects JSON requests; include JSON in Accept to avoid 406 from `accepts ["json"]`.
        urlRequest.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        // Add functional headers (auth + device ID)
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Add diagnostic headers (conditional on user preference)
        let requestId = await deviceKeyService.applyDiagnosticsHeaders(to: &urlRequest)
        let intentType = request.intent?.type ?? "none"
        debugLog("Starting stream request provider=\(provider) intent=\(intentType) hasImages=\(request.hasImages) requestId=\(requestId ?? "nil") url=\(url.absoluteString)")
        debugLog("Awaiting response headers (idle timeout=\(Int(urlRequest.timeoutInterval))s)")

        var didReceiveHeaders = false

        let headerWatchdog = Task { [weak self] in
            // Periodic breadcrumbs so we can tell if we're stuck pre-headers.
            for seconds in [5, 10, 15] {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                } catch {
                    return
                }
                self?.debugLog("Still awaiting response headers after \(seconds)s…")
            }
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            headerWatchdog.cancel()

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    onError(ProxyLLMError.validationError("Invalid response"))
                }
                return
            }

            // Get response request ID (prefer server's, fall back to what we sent)
            let responseRequestId = httpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? requestId
            debugLog("Response status=\(httpResponse.statusCode) contentType=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil") responseRequestId=\(responseRequestId ?? "nil")")
            didReceiveHeaders = true

            // Read resolved provider/model from proxy headers
            let resolvedProvider = httpResponse.value(forHTTPHeaderField: "X-Ticker-Provider") ?? provider
            let resolvedModel = httpResponse.value(forHTTPHeaderField: "X-Ticker-Model") ?? "default"
            debugLog("Resolved provider=\(resolvedProvider) model=\(resolvedModel) (requested provider=\(provider))")

            // Notify caller of resolved model (before streaming starts)
            if let onModelSelected {
                await MainActor.run {
                    onModelSelected(resolvedProvider, resolvedModel)
                }
            }

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
            var dataLines: [String] = []
            var didReceiveAnyEvent = false

            func dispatchEventIfReady() async -> Bool {
                guard let eventType = currentEventType else {
                    dataLines.removeAll(keepingCapacity: true)
                    return false
                }

                let dataLine = dataLines.joined(separator: "\n")
                didReceiveAnyEvent = true
                debugLog("Dispatch event=\(eventType) dataLen=\(dataLine.count)")
                await handleSSEEvent(
                    eventType: eventType,
                    dataLine: dataLine,
                    requestId: responseRequestId ?? "unknown",
                    onChunk: onChunk,
                    onComplete: onComplete,
                    onError: onError
                )

                currentEventType = nil
                dataLines.removeAll(keepingCapacity: true)

                return eventType == "done" || eventType == "error"
            }

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !didReceiveAnyEvent && !line.isEmpty {
                    // Lightweight signal that the stream is alive.
                    debugLog("Received SSE line (len=\(line.count))")
                }

                if line.hasPrefix("event:") {
                    // If we see a new event type and we already have data for the previous event,
                    // dispatch the previous event even if the blank-line separator isn't surfaced
                    // by URLSession's line iterator.
                    if currentEventType != nil, !dataLines.isEmpty {
                        if await dispatchEventIfReady() {
                            return
                        }
                    }
                    currentEventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    dataLines.append(data)

                    // Most proxy SSE events are single-line JSON. If the blank line separator
                    // isn't delivered, dispatch immediately once we have a complete data line.
                    if let eventType = currentEventType,
                       dataLines.count == 1,
                       ["delta", "done", "error"].contains(eventType),
                       data.hasPrefix("{"),
                       data.hasSuffix("}") {
                        if await dispatchEventIfReady() {
                            return
                        }
                    }
                } else if line.isEmpty {
                    if await dispatchEventIfReady() {
                        return
                    }
                } else {
                    continue
                }
            }

            if await dispatchEventIfReady() {
                return
            }

            if !didReceiveAnyEvent {
                debugLog("Stream ended without dispatching any SSE events")
            } else {
                debugLog("Stream ended without done/error event; completing")
            }

            // Stream ended without done event
            await MainActor.run { onComplete() }

        } catch let urlError as URLError {
            headerWatchdog.cancel()
            if urlError.code == .timedOut {
                let timeoutSeconds = Int(urlRequest.timeoutInterval)
                if didReceiveHeaders {
                    debugLog("Proxy stream failed: timed out during stream (idle timeout)")
                } else {
                    debugLog("Proxy stream failed: timed out waiting for response headers")
                }
                await MainActor.run { onError(ProxyLLMError.timeout(seconds: timeoutSeconds)) }
            } else {
                debugLog("Proxy stream failed: \(urlError.localizedDescription)")
                await MainActor.run { onError(ProxyLLMError.unreachable) }
            }
        } catch {
            headerWatchdog.cancel()
            debugLog("Proxy stream failed: \(error.localizedDescription)")
            await MainActor.run {
                onError(ProxyLLMError.unreachable)
            }
        }
    }

    // MARK: - Non-Streaming Methods

    /// Generate a restatement/heading for user input (non-streaming)
    /// Returns nil if restatement is "NONE" or empty
    func generateRestatement(for input: String) async -> String? {
        // Get credentials from device key service
        let headers = await deviceKeyService.getProxyHeaders()
        guard let headers else {
            debugLog("Restatement failed: no proxy headers")
            return nil
        }

        // Build request URL
        guard let url = URL(string: "\(proxyBaseURL)/v1/llm/request") else {
            debugLog("Restatement failed: invalid proxy URL")
            return nil
        }

        // Build request body (non-streaming)
        let provider = determineProvider(for: LLMRequest(systemPrompt: "", messages: []))
        let messages: [[String: Any]] = [
            ["role": "system", "content": Prompts.restatement],
            ["role": "user", "content": input]
        ]
        let requestBody: [String: Any] = [
            "model": "default",
            "messages": messages,
            "provider": provider,
            "stream": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            debugLog("Restatement failed: failed to encode request")
            return nil
        }

        // Build URL request
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = 30  // Short timeout for quick restatement
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add functional headers
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Add diagnostic headers
        let requestId = await deviceKeyService.applyDiagnosticsHeaders(to: &urlRequest)
        debugLog("Restatement request requestId=\(requestId ?? "nil")")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("Restatement failed: invalid response type")
                return nil
            }

            // Record request ID if available
            if let id = httpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? requestId {
                await deviceKeyService.recordRequestId(id, endpoint: "llm")
            }

            guard httpResponse.statusCode == 200 else {
                debugLog("Restatement failed: status \(httpResponse.statusCode)")
                return nil
            }

            // Parse response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outputText = json["output_text"] as? String else {
                debugLog("Restatement failed: invalid response format")
                return nil
            }

            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "NONE" || trimmed.isEmpty {
                debugLog("Restatement returned NONE")
                return nil
            }

            debugLog("Restatement generated: \(trimmed.prefix(50))...")
            return trimmed

        } catch {
            debugLog("Restatement failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a short label for a modifier prompt (non-streaming)
    func generateLabel(for prompt: String) async throws -> String {
        // Get credentials from device key service
        let headers = await deviceKeyService.getProxyHeaders()
        guard let headers else {
            throw ProxyLLMError.invalidKey
        }

        // Build request URL
        guard let url = URL(string: "\(proxyBaseURL)/v1/llm/request") else {
            throw ProxyLLMError.validationError("Invalid proxy URL")
        }

        // Build request body (non-streaming)
        let provider = determineProvider(for: LLMRequest(systemPrompt: "", messages: []))
        let messages: [[String: Any]] = [
            ["role": "system", "content": Prompts.modifierLabel],
            ["role": "user", "content": prompt]
        ]
        let requestBody: [String: Any] = [
            "model": "default",
            "messages": messages,
            "provider": provider,
            "stream": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw ProxyLLMError.validationError("Failed to encode request")
        }

        // Build URL request
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add functional headers
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Add diagnostic headers
        let requestId = await deviceKeyService.applyDiagnosticsHeaders(to: &urlRequest)
        debugLog("Label generation request requestId=\(requestId ?? "nil")")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyLLMError.validationError("Invalid response")
        }

        // Record request ID if available
        if let id = httpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? requestId {
            await deviceKeyService.recordRequestId(id, endpoint: "llm")
        }

        guard httpResponse.statusCode == 200 else {
            debugLog("Label generation failed: status \(httpResponse.statusCode)")
            throw ProxyLLMError.serverError(statusCode: httpResponse.statusCode, requestId: requestId)
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputText = json["output_text"] as? String else {
            throw ProxyLLMError.validationError("Invalid response format")
        }

        let label = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("Label generated: \(label)")
        return label
    }

    /// Apply a modifier to content with streaming
    func applyModifier(
        currentContent: String,
        modifierPrompt: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async {
        // Build a streaming request for the modifier
        let userPrompt = "Content to transform:\n\n\(currentContent)\n\n---\n\nInstruction: \(modifierPrompt)"
        let request = LLMRequest(
            systemPrompt: Prompts.applyModifier,
            messages: [LLMMessage(role: "user", content: userPrompt)],
            temperature: 0.7,
            maxTokens: 2048
        )

        // Use the existing stream method
        await stream(
            request: request,
            onChunk: onChunk,
            onComplete: onComplete,
            onError: onError
        )
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
                        print("[ProxyLLMService] Dropping non-base64 image URL (not supported in alpha): \(imageURL.prefix(50))...")
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

    // MARK: - Provider Selection

    /// Determine which provider to use based on user settings (preference hint for proxy)
    private func determineProvider(for request: LLMRequest) -> String {
        // This is a preference hint - the proxy may override based on intent
        // (e.g., search intent routes to Perplexity regardless of this preference)
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
        switch eventType {
        case "delta":
            // data: {"text": "..."}
            guard let jsonData = dataLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }
            if let text = json["text"] as? String {
                await MainActor.run { onChunk(text) }
            }

        case "done":
            // data: {"usage": {...}}
            debugLog("Done event received; completing stream")
            await MainActor.run { onComplete() }

        case "error":
            // data: {"error": {"code": "...", "message": "...", "details": {...}}}
            guard let jsonData = dataLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                await MainActor.run { onError(ProxyLLMError.validationError("Stream error")) }
                return
            }
            if let errorObj = json["error"] as? [String: Any] {
                let code = errorObj["code"] as? String ?? "unknown"
                let message = errorObj["message"] as? String ?? "Stream error"
                let details = errorObj["details"] as? [String: Any]
                let detailsKeys = details.map { $0.keys.sorted().joined(separator: ",") } ?? "nil"
                let reason = (details?["reason"] as? String) ?? "nil"
                debugLog("Error event received code=\(code) message=\(message) detailsKeys=\(detailsKeys) reason=\(reason)")
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
