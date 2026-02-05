import Foundation

// MARK: - Auth State

/// Proxy authentication state machine
enum ProxyAuthState: String, Codable {
    case unregistered           // No key entered
    case validating             // Currently validating key with server
    case active                 // Key validated successfully
    case blockedInvalid         // Key invalid or expired
    case blockedRevoked         // Key revoked by admin
    case blockedBoundElsewhere  // Key bound to different device
    case degradedOffline        // Network unavailable, cached key present

    var isUsable: Bool {
        switch self {
        case .active, .degradedOffline:
            return true
        default:
            return false
        }
    }

    var requiresGate: Bool {
        switch self {
        case .active, .degradedOffline:
            return false
        default:
            return true
        }
    }
}

// MARK: - Response Types

/// Response from proxy `/v1/auth/validate` endpoint
struct ProxyAuthValidationResponse: Codable {
    let supportId: String
    let boundDeviceId: String?
    let limits: Limits?
    let usage: Usage?

    struct Limits: Codable {
        let reqsPerMin: Int?
        let tokensPerDay: Int?
        let tokensPerMonth: Int?

        enum CodingKeys: String, CodingKey {
            case reqsPerMin = "reqs_per_min"
            case tokensPerDay = "tokens_per_day"
            case tokensPerMonth = "tokens_per_month"
        }
    }

    struct Usage: Codable {
        let reqsThisMinute: Int?
        let tokensToday: Int?
        let tokensThisMonth: Int?
        let dayResetAt: String?
        let monthResetAt: String?

        enum CodingKeys: String, CodingKey {
            case reqsThisMinute = "reqs_this_minute"
            case tokensToday = "tokens_today"
            case tokensThisMonth = "tokens_this_month"
            case dayResetAt = "day_reset_at"
            case monthResetAt = "month_reset_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case supportId = "support_id"
        case boundDeviceId = "bound_device_id"
        case limits, usage
    }
}

/// Proxy error response structure
struct ProxyErrorResponse: Codable {
    let error: ErrorDetail

    struct ErrorDetail: Codable {
        let code: String
        let message: String
    }
}

// MARK: - Stored Data

/// Stored device data (non-sensitive fields can be cached to disk)
struct DeviceKeyData: Codable {
    var deviceId: String
    var deviceKey: String?
    var supportId: String?
    var validatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceKey = "device_key"
        case supportId = "support_id"
        case validatedAt = "validated_at"
    }
}

// MARK: - Errors

/// Proxy error codes (from proxy API)
enum ProxyErrorCode: String {
    case invalidKey = "invalid_key"
    case keyRevoked = "key_revoked"
    case keyBoundElsewhere = "key_bound_elsewhere"
    case rateLimited = "rate_limited"
    case unknown

    init(rawValue: String) {
        switch rawValue {
        case "invalid_key": self = .invalidKey
        case "key_revoked": self = .keyRevoked
        case "key_bound_elsewhere": self = .keyBoundElsewhere
        case "rate_limited": self = .rateLimited
        default: self = .unknown
        }
    }
}

/// Errors from device key operations
enum DeviceKeyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidKey
    case keyRevoked
    case boundToOtherDevice
    case rateLimited
    case payloadTooLarge
    case notFound
    case forbidden
    case serverError(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid proxy URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidKey:
            return "Invalid or expired device key"
        case .keyRevoked:
            return "This device key has been revoked. Contact support for assistance."
        case .boundToOtherDevice:
            return "This key is bound to a different device. Contact support for assistance."
        case .rateLimited:
            return "Too many requests. Please try again in a minute."
        case .payloadTooLarge:
            return "Attachment is too large. Maximum size is 10MB."
        case .notFound:
            return "Resource not found."
        case .forbidden:
            return "Access denied."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .networkError:
            return "Unable to reach server. Check your internet connection."
        }
    }

    /// Maps error to auth state, or nil for non-auth-fatal errors (like rate limiting)
    var authState: ProxyAuthState? {
        switch self {
        case .invalidKey: return .blockedInvalid
        case .keyRevoked: return .blockedRevoked
        case .boundToOtherDevice: return .blockedBoundElsewhere
        case .networkError: return .degradedOffline
        case .rateLimited, .serverError, .invalidURL, .invalidResponse,
             .payloadTooLarge, .notFound, .forbidden:
            // These are transient/non-auth errors - don't change auth state
            return nil
        }
    }
}

// MARK: - Request ID Entry (D4)

/// Entry in the request ID ring buffer for support bundle
struct RequestIdEntry {
    let requestId: String
    let timestamp: Date
    let endpoint: String  // "llm", "feedback", "auth", etc.
}

// MARK: - Feedback Response Types

/// Response from proxy `/v1/feedback` endpoint
struct FeedbackResponse: Codable {
    let feedbackId: String

    enum CodingKeys: String, CodingKey {
        case feedbackId = "feedback_id"
    }
}

/// Response from proxy `/v1/feedback/:id/attachments` endpoint
struct AttachmentCreateResponse: Codable {
    let attachmentId: String
    let upload: Upload

    struct Upload: Codable {
        let url: String
        let headers: [String: String]
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case url, headers
            case expiresAt = "expires_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case upload
    }
}

// MARK: - Service

/// Manages device key storage and validation against Ticker-Proxy
actor DeviceKeyService {
    static let shared = DeviceKeyService()

    // MARK: - State

    private var cachedData: DeviceKeyData?
    private(set) var currentState: ProxyAuthState = .unregistered

    /// Cached limits from last validation
    private var cachedLimits: ProxyAuthValidationResponse.Limits?
    /// Cached usage from last validation
    private var cachedUsage: ProxyAuthValidationResponse.Usage?

    // MARK: - Request ID Tracking (D4)

    /// Ring buffer of recent request IDs (last 50) for support bundle
    private var recentRequestIds: [RequestIdEntry] = []
    private let maxRequestIds = 50

    /// Callback invoked when auth state changes (called on MainActor)
    /// Note: nonisolated to allow setting from outside actor context
    nonisolated(unsafe) var onStateChange: ((ProxyAuthState) -> Void)?

    // MARK: - Configuration

    /// Proxy base URL - can be overridden via TICKER_PROXY_URL env var or UserDefaults
    private var proxyBaseURL: String {
        // Check environment variable first (for debugging)
        if let envURL = ProcessInfo.processInfo.environment["TICKER_PROXY_URL"], !envURL.isEmpty {
            return envURL
        }
        // Check UserDefaults (for dev builds)
        if let defaultsURL = UserDefaults.standard.string(forKey: "TickerProxyURL"), !defaultsURL.isEmpty {
            return defaultsURL
        }
        // Production default
        return "https://ticker-proxy.fly.dev"
    }

    private var fileURL: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let tickerDir = appSupport.appendingPathComponent("Ticker", isDirectory: true)
        return tickerDir.appendingPathComponent("device.json")
    }

    /// Directory that contains `device.json`
    private var deviceDirectoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    /// Ensure Application Support directory exists and is private to the user (best effort).
    /// `device.json` contains the plaintext device key, so we prefer restrictive permissions.
    private func ensureDeviceDirectoryExists(fileManager: FileManager = .default) {
        let dir = deviceDirectoryURL
        do {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Best-effort; do not crash the app for a permissions edge case.
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // If directory already existed, `createDirectory` won't update perms.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Stale temp files created by prior versions of `save(_:)` or interrupted writes.
    /// These can contain plaintext device keys and must be cleaned up on startup.
    private func cleanupStaleDeviceTempFiles(fileManager: FileManager = .default) {
        let dir = deviceDirectoryURL

        // Old implementation wrote to this fixed filename.
        let legacyTempURL = fileURL.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: legacyTempURL.path) {
            try? fileManager.removeItem(at: legacyTempURL)
        }

        // New implementation writes to `device.json.tmp.<uuid>`; if the app crashes mid-save,
        // these may be left behind. Remove any such leftovers (best effort).
        if let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in entries {
                let name = url.lastPathComponent
                if name.hasPrefix("device.json.tmp.") {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Best-effort permission hardening for the device file (contains plaintext device key).
    private func hardenDeviceFilePermissions(fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Initialization

    /// Initialize and determine initial state based on stored data
    func initialize() async {
        let data = loadOrCreate()

        if data.deviceKey != nil {
            // Have a cached key - need to validate with server
            await revalidate()
        } else {
            await setState(.unregistered)
        }
    }

    // MARK: - State Management

    private func setState(_ newState: ProxyAuthState) async {
        guard newState != currentState else { return }
        currentState = newState

        // Notify on main actor
        await MainActor.run {
            onStateChange?(newState)
        }
    }

    // MARK: - Public API (canonical bridge names)

    /// Load current proxy auth state - returns state + support_id if available
    func loadProxyAuth() -> (state: ProxyAuthState, supportId: String?, deviceId: String) {
        let data = loadOrCreate()
        return (
            state: currentState,
            supportId: data.supportId,
            deviceId: data.deviceId
        )
    }

    /// Get cached limits and usage from last validation
    func getLimitsAndUsage() -> (limits: ProxyAuthValidationResponse.Limits?, usage: ProxyAuthValidationResponse.Usage?) {
        return (limits: cachedLimits, usage: cachedUsage)
    }

    /// Set and validate a device key
    func setProxyDeviceKey(_ key: String) async throws -> ProxyAuthValidationResponse {
        await setState(.validating)

        do {
            let response = try await validateWithServer(key: key)

            // Store validated key
            var data = loadOrCreate()
            data.deviceKey = key
            data.supportId = response.supportId
            data.validatedAt = Date()
            save(data)

            // Cache limits and usage
            cachedLimits = response.limits
            cachedUsage = response.usage

            await setState(.active)
            return response

        } catch let error as DeviceKeyError {
            // For first-time key entry:
            // - Network errors: stay unregistered (no cached key to fall back on)
            // - Rate limit/transient errors: stay unregistered, let user retry
            // - Auth errors (invalid/revoked/bound): transition to blocked state
            if let newState = error.authState {
                // Only network errors can go to degradedOffline, but not during first entry
                if case .networkError = error {
                    await setState(.unregistered)
                } else {
                    await setState(newState)
                }
            } else {
                // Transient error (rate limit, server error) - stay unregistered
                await setState(.unregistered)
            }
            throw error
        } catch {
            await setState(.blockedInvalid)
            throw error
        }
    }

    /// Clear stored key
    func clearProxyDeviceKey() async {
        var data = loadOrCreate()
        data.deviceKey = nil
        data.supportId = nil
        data.validatedAt = nil
        save(data)
        await setState(.unregistered)
    }

    /// Re-validate cached key with server (called on startup or when needed)
    func revalidate() async {
        let data = loadOrCreate()
        guard let key = data.deviceKey else {
            await setState(.unregistered)
            return
        }

        await setState(.validating)

        do {
            let response = try await validateWithServer(key: key)

            // Update cached data
            var updatedData = data
            updatedData.supportId = response.supportId
            updatedData.validatedAt = Date()
            save(updatedData)

            // Cache limits and usage
            cachedLimits = response.limits
            cachedUsage = response.usage

            await setState(.active)

        } catch let error as DeviceKeyError {
            // Handle based on error type:
            // - Network error: degraded offline (cached key still usable)
            // - Auth errors (invalid/revoked/bound): clear key, transition to blocked
            // - Transient errors (rate limit, server error): stay active if already active
            if let newState = error.authState {
                if case .degradedOffline = newState {
                    // Network error - allow degraded mode
                    await setState(.degradedOffline)
                } else {
                    // Auth error - key is invalid/revoked/bound elsewhere, clear it
                    await clearProxyDeviceKey()
                    await setState(newState)
                }
            } else {
                // Transient error (rate limit, server error) - keep current state
                // If we were validating from active, go back to active
                // If we were validating from unregistered, stay unregistered
                // For simplicity, just go back to active since we have a cached key
                await setState(.active)
            }
        } catch {
            await setState(.blockedInvalid)
        }
    }

    /// Get credentials for proxy requests (used by other services)
    func getCredentials() -> (deviceId: String, deviceKey: String)? {
        guard currentState.isUsable else { return nil }
        let data = loadOrCreate()
        guard let key = data.deviceKey else { return nil }
        return (data.deviceId, key)
    }

    /// Get functional headers for proxy requests (auth + device ID only)
    /// Use applyDiagnosticsHeaders() separately to add conditional diagnostic headers
    func getProxyHeaders() -> [String: String]? {
        guard let credentials = getCredentials() else { return nil }

        // Functional headers only (required for auth)
        return [
            "Authorization": "Bearer \(credentials.deviceKey)",
            "X-Ticker-Device-Id": credentials.deviceId
        ]
    }

    /// Apply diagnostic headers to a URLRequest (only if diagnostics enabled)
    /// Call this after setting functional headers to conditionally add:
    /// - X-Ticker-App-Version
    /// - X-Ticker-Platform
    /// - X-Ticker-OS-Version
    /// - X-Ticker-Request-Id
    /// Returns the generated request ID if sent, nil otherwise
    @discardableResult
    func applyDiagnosticsHeaders(to request: inout URLRequest) -> String? {
        guard SettingsService.shared.diagnosticsEnabled else {
            return nil
        }

        let requestId = UUID().uuidString
        request.setValue(appVersion(), forHTTPHeaderField: "X-Ticker-App-Version")
        request.setValue("macOS", forHTTPHeaderField: "X-Ticker-Platform")
        request.setValue(osVersion(), forHTTPHeaderField: "X-Ticker-OS-Version")
        request.setValue(requestId, forHTTPHeaderField: "X-Ticker-Request-Id")

        return requestId
    }

    // MARK: - Request ID Tracking (D4)

    /// Record a request ID for inclusion in support bundle
    func recordRequestId(_ id: String, endpoint: String) {
        recentRequestIds.append(RequestIdEntry(
            requestId: id,
            timestamp: Date(),
            endpoint: endpoint
        ))
        // Keep only the last N entries
        if recentRequestIds.count > maxRequestIds {
            recentRequestIds.removeFirst()
        }
    }

    // MARK: - Support Bundle (D4)

    /// Generate support bundle for troubleshooting (no keys or content)
    func getSupportBundle() -> [String: Any] {
        let data = loadOrCreate()
        let formatter = ISO8601DateFormatter()

        return [
            "generated_at": formatter.string(from: Date()),
            "app_version": appVersion(),
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "os_version": osVersion(),
            "device_id": data.deviceId,
            "support_id": data.supportId ?? "none",
            "auth_state": currentState.rawValue,
            "diagnostics_enabled": SettingsService.shared.diagnosticsEnabled,
            "recent_request_ids": recentRequestIds.map { entry in
                [
                    "request_id": entry.requestId,
                    "timestamp": formatter.string(from: entry.timestamp),
                    "endpoint": entry.endpoint
                ]
            },
            "usage": [
                "tokens_today": cachedUsage?.tokensToday ?? 0,
                "tokens_this_month": cachedUsage?.tokensThisMonth ?? 0
            ]
        ]
    }

    // MARK: - Feedback Submission (D5)

    /// Maximum attachment size (10MB per OpenAPI spec)
    private static let maxAttachmentBytes = 10 * 1024 * 1024

    /// Get the most recent LLM request ID for feedback correlation
    private func getMostRecentLLMRequestId() -> String? {
        recentRequestIds.last { $0.endpoint == "llm" }?.requestId
    }

    /// Submit feedback (bug report or feature request) to proxy
    /// - Parameters:
    ///   - type: "bug" or "feature"
    ///   - title: Short summary
    ///   - description: Optional detailed description
    ///   - screenshotBase64: Optional base64-encoded screenshot (without data: prefix)
    ///   - screenshotContentType: MIME type of screenshot (e.g., "image/png", "image/jpeg")
    /// - Returns: Feedback ID for user reference (e.g., "fb_abc123")
    func submitFeedback(
        type: String,
        title: String,
        description: String?,
        screenshotBase64: String?,
        screenshotContentType: String? = nil
    ) async throws -> String {
        guard let credentials = getCredentials() else {
            throw DeviceKeyError.invalidKey
        }

        // Step 1: Submit feedback with metadata (support bundle)
        let feedbackId = try await postFeedback(
            type: type,
            title: title,
            description: description,
            deviceKey: credentials.deviceKey
        )

        // Step 2: If screenshot provided, upload as attachment
        if let base64 = screenshotBase64,
           let imageData = Data(base64Encoded: base64) {
            // Enforce 10MB limit
            guard imageData.count <= Self.maxAttachmentBytes else {
                DebugLog.log("[DeviceKeyService] Attachment too large: \(imageData.count) bytes (max \(Self.maxAttachmentBytes))")
                throw DeviceKeyError.payloadTooLarge
            }

            do {
                let contentType = screenshotContentType ?? "image/png"
                let fileExtension = contentType.components(separatedBy: "/").last ?? "png"
                try await uploadAttachment(
                    feedbackId: feedbackId,
                    imageData: imageData,
                    contentType: contentType,
                    filename: "screenshot.\(fileExtension)",
                    deviceKey: credentials.deviceKey
                )
            } catch {
                // Log but don't fail the whole feedback submission
                DebugLog.log("[DeviceKeyService] Attachment upload failed (\(DebugLog.errorSummary(error)))")
            }
        }

        return feedbackId
    }

    /// POST feedback to proxy
    private func postFeedback(
        type: String,
        title: String,
        description: String?,
        deviceKey: String
    ) async throws -> String {
        guard let url = URL(string: "\(proxyBaseURL)/v1/feedback") else {
            throw DeviceKeyError.invalidURL
        }

        // Build request body with device_key in body (not header)
        var requestBody: [String: Any] = [
            "device_key": deviceKey,
            "type": type,
            "title": title,
            "description": description ?? "",
            "metadata": getSupportBundle()
        ]

        // Include most recent LLM request ID for triage (P1)
        if let relatedRequestId = getMostRecentLLMRequestId() {
            requestBody["related_request_id"] = relatedRequestId
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw DeviceKeyError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Diagnostic headers (conditional)
        let localRequestId = applyDiagnosticsHeaders(to: &request)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeviceKeyError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceKeyError.invalidResponse
        }

        // Record request ID if available (prefer server's response header)
        if let responseRequestId = httpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? localRequestId {
            recordRequestId(responseRequestId, endpoint: "feedback")
        }

        switch httpResponse.statusCode {
        case 200:
            let feedbackResponse = try JSONDecoder().decode(FeedbackResponse.self, from: responseData)
            return feedbackResponse.feedbackId

        case 401:
            // Auth failed - revalidate state so UI updates
            await revalidate()
            throw DeviceKeyError.invalidKey

        case 403:
            throw DeviceKeyError.forbidden

        case 404:
            throw DeviceKeyError.notFound

        case 413:
            throw DeviceKeyError.payloadTooLarge

        case 429:
            throw DeviceKeyError.rateLimited

        default:
            throw DeviceKeyError.serverError(httpResponse.statusCode)
        }
    }

    /// Upload screenshot attachment to feedback
    /// Three-step flow: create → PUT to presigned URL → complete
    private func uploadAttachment(
        feedbackId: String,
        imageData: Data,
        contentType: String,
        filename: String,
        deviceKey: String
    ) async throws {
        // Step 1: Create attachment and get presigned URL
        guard let createURL = URL(string: "\(proxyBaseURL)/v1/feedback/\(feedbackId)/attachments") else {
            throw DeviceKeyError.invalidURL
        }

        let createBody: [String: Any] = [
            "device_key": deviceKey,
            "filename": filename,
            "content_type": contentType,
            "byte_size": imageData.count
        ]

        guard let createBodyData = try? JSONSerialization.data(withJSONObject: createBody) else {
            throw DeviceKeyError.invalidResponse
        }

        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.httpBody = createBodyData
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Diagnostic headers (conditional)
        let localCreateRequestId = applyDiagnosticsHeaders(to: &createRequest)

        let (createResponseData, createResponse) = try await URLSession.shared.data(for: createRequest)

        guard let createHttpResponse = createResponse as? HTTPURLResponse else {
            throw DeviceKeyError.invalidResponse
        }

        // Record request ID if available (prefer server's response header)
        if let createResponseRequestId = createHttpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? localCreateRequestId {
            recordRequestId(createResponseRequestId, endpoint: "feedback-attachment")
        }

        // Handle error codes
        switch createHttpResponse.statusCode {
        case 200:
            break // Continue to decode response
        case 401:
            await revalidate()
            throw DeviceKeyError.invalidKey
        case 403:
            throw DeviceKeyError.forbidden
        case 404:
            throw DeviceKeyError.notFound
        case 413:
            throw DeviceKeyError.payloadTooLarge
        case 429:
            throw DeviceKeyError.rateLimited
        default:
            throw DeviceKeyError.serverError(createHttpResponse.statusCode)
        }

        let attachmentResponse = try JSONDecoder().decode(AttachmentCreateResponse.self, from: createResponseData)

        // Step 2: PUT image data to presigned URL
        guard let uploadURL = URL(string: attachmentResponse.upload.url) else {
            throw DeviceKeyError.invalidURL
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.httpBody = imageData
        // Add headers from presigned URL response
        for (key, value) in attachmentResponse.upload.headers {
            uploadRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (_, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let uploadHttpResponse = uploadResponse as? HTTPURLResponse,
              (200...299).contains(uploadHttpResponse.statusCode) else {
            throw DeviceKeyError.serverError((uploadResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Step 3: Mark attachment as complete
        guard let completeURL = URL(string: "\(proxyBaseURL)/v1/feedback/\(feedbackId)/attachments/\(attachmentResponse.attachmentId)/complete") else {
            throw DeviceKeyError.invalidURL
        }

        let completeBody: [String: Any] = ["device_key": deviceKey]
        guard let completeBodyData = try? JSONSerialization.data(withJSONObject: completeBody) else {
            throw DeviceKeyError.invalidResponse
        }

        var completeRequest = URLRequest(url: completeURL)
        completeRequest.httpMethod = "POST"
        completeRequest.httpBody = completeBodyData
        completeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Diagnostic headers (conditional)
        let localCompleteRequestId = applyDiagnosticsHeaders(to: &completeRequest)

        let (_, completeResponse) = try await URLSession.shared.data(for: completeRequest)

        guard let completeHttpResponse = completeResponse as? HTTPURLResponse else {
            throw DeviceKeyError.invalidResponse
        }

        // Record request ID if available (prefer server's response header)
        if let completeResponseRequestId = completeHttpResponse.value(forHTTPHeaderField: "X-Ticker-Request-Id") ?? localCompleteRequestId {
            recordRequestId(completeResponseRequestId, endpoint: "feedback-attachment-complete")
        }

        // Handle error codes
        switch completeHttpResponse.statusCode {
        case 200:
            break // Success
        case 401:
            await revalidate()
            throw DeviceKeyError.invalidKey
        case 403:
            throw DeviceKeyError.forbidden
        case 404:
            throw DeviceKeyError.notFound
        case 429:
            throw DeviceKeyError.rateLimited
        default:
            throw DeviceKeyError.serverError(completeHttpResponse.statusCode)
        }
    }

    // MARK: - Private Implementation

    /// Load existing data or create new with fresh device_id
    private func loadOrCreate() -> DeviceKeyData {
        if let cached = cachedData {
            return cached
        }

        let fileManager = FileManager.default

        ensureDeviceDirectoryExists(fileManager: fileManager)
        cleanupStaleDeviceTempFiles(fileManager: fileManager)

        // Try to load existing
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(DeviceKeyData.self, from: data) {
                cachedData = decoded
                return decoded
            }
        }

        // Create new with fresh device_id
        let newData = DeviceKeyData(
            deviceId: UUID().uuidString,
            deviceKey: nil,
            supportId: nil,
            validatedAt: nil
        )
        save(newData)
        return newData
    }

    /// Save device data to disk atomically
    private func save(_ data: DeviceKeyData) {
        cachedData = data
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let encoded = try? encoder.encode(data) else { return }

        let fileManager = FileManager.default
        ensureDeviceDirectoryExists(fileManager: fileManager)

        // Write to a unique temp file in the same directory, then atomically replace.
        // This avoids leaving a fixed `device.json.tmp` file behind.
        let tempURL = deviceDirectoryURL.appendingPathComponent("device.json.tmp.\(UUID().uuidString)")
        do {
            try encoded.write(to: tempURL, options: [])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }

            hardenDeviceFilePermissions(fileManager: fileManager)
        } catch {
            // Best-effort cleanup; temp file may contain plaintext key.
            try? fileManager.removeItem(at: tempURL)

            // Fallback: direct atomic write (system-managed temp). Still harden perms afterwards.
            do {
                try encoded.write(to: fileURL, options: .atomic)
                hardenDeviceFilePermissions(fileManager: fileManager)
            } catch {
                // If even fallback fails, we keep cachedData in memory; caller will still function
                // for this session (but persistence is compromised).
            }
        }
    }

    /// Validate key with server
    private func validateWithServer(key: String) async throws -> ProxyAuthValidationResponse {
        let data = loadOrCreate()

        guard let url = URL(string: "\(proxyBaseURL)/v1/auth/validate") else {
            throw DeviceKeyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Functional headers (always sent)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(data.deviceId, forHTTPHeaderField: "X-Ticker-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Diagnostic headers (conditional)
        applyDiagnosticsHeaders(to: &request)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeviceKeyError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceKeyError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let validation = try decoder.decode(ProxyAuthValidationResponse.self, from: responseData)

            // Check if bound to different device
            if let boundDeviceId = validation.boundDeviceId {
                let local = data.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
                let remote = boundDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)

                // Prefer UUID parsing to avoid case/format mismatches (proxy may normalize UUID strings).
                if let localUUID = UUID(uuidString: local), let remoteUUID = UUID(uuidString: remote) {
                    if localUUID != remoteUUID {
                        throw DeviceKeyError.boundToOtherDevice
                    }
                } else if local.lowercased() != remote.lowercased() {
                    throw DeviceKeyError.boundToOtherDevice
                }
            }

            return validation

        case 401:
            // Parse structured error code
            if let errorResponse = try? JSONDecoder().decode(ProxyErrorResponse.self, from: responseData) {
                switch ProxyErrorCode(rawValue: errorResponse.error.code) {
                case .keyRevoked:
                    throw DeviceKeyError.keyRevoked
                case .keyBoundElsewhere:
                    throw DeviceKeyError.boundToOtherDevice
                default:
                    throw DeviceKeyError.invalidKey
                }
            }
            throw DeviceKeyError.invalidKey

        case 429:
            throw DeviceKeyError.rateLimited

        default:
            throw DeviceKeyError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Helpers

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
