import Foundation

/// Generates and manages embeddings via OpenAI API
/// @note RAG (semantic search) is disabled for alpha (proxyOnlyMode = true).
/// All embed() calls will throw EmbeddingError.disabled in proxy-only mode.
final class EmbeddingService {
    private let settings: SettingsService
    private let baseURL = "https://api.openai.com/v1/embeddings"
    private let model = "text-embedding-3-small"
    static let dimensions = 1536
    private let maxBatchSize = 100  // OpenAI allows up to 2048 inputs per request

    init(settings: SettingsService = .shared) {
        self.settings = settings
    }

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

    // MARK: - Public Interface

    /// Generate embedding for a single text
    func embed(text: String) async throws -> [Float] {
        let results = try await embedBatch(texts: [text])
        guard let first = results.first else {
            throw EmbeddingError.emptyResponse
        }
        return first
    }

    /// Generate embeddings for multiple texts (batched)
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        // Explicit check: RAG/embeddings are disabled in proxy-only mode
        guard !SettingsService.proxyOnlyMode else {
            throw EmbeddingError.disabled
        }

        guard let apiKey else {
            throw EmbeddingError.notConfigured
        }

        guard !texts.isEmpty else {
            return []
        }

        var allEmbeddings: [[Float]] = []

        // Process in batches of maxBatchSize
        for batchStart in stride(from: 0, to: texts.count, by: maxBatchSize) {
            let batchEnd = min(batchStart + maxBatchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            let requestBody: [String: Any] = [
                "model": model,
                "input": batch
            ]

            guard let url = URL(string: baseURL),
                  let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
                throw EmbeddingError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmbeddingError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                // Try to extract error message from response
                var errorMessage = "HTTP \(httpResponse.statusCode)"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    errorMessage = message
                }
                throw EmbeddingError.apiError(httpResponse.statusCode, errorMessage)
            }

            let embeddings = try parseEmbeddingResponse(data)
            allEmbeddings.append(contentsOf: embeddings)
        }

        return allEmbeddings
    }

    // MARK: - Binary Serialization

    /// Convert embedding array to binary blob for storage
    static func toBlob(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Convert binary blob back to embedding array
    static func fromBlob(_ data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    // MARK: - Private

    private func parseEmbeddingResponse(_ data: Data) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.invalidResponse
        }

        // Sort by index to maintain order (OpenAI may return in different order)
        let sorted = dataArray.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }

        return sorted.compactMap { item -> [Float]? in
            guard let embedding = item["embedding"] as? [Double] else { return nil }
            return embedding.map { Float($0) }
        }
    }
}

// MARK: - Errors

enum EmbeddingError: LocalizedError {
    case disabled
    case notConfigured
    case invalidRequest
    case invalidResponse
    case emptyResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Embeddings are disabled (RAG not available in alpha)"
        case .notConfigured:
            return "OpenAI API key not configured"
        case .invalidRequest:
            return "Failed to build embedding request"
        case .invalidResponse:
            return "Invalid embedding response"
        case .emptyResponse:
            return "Empty embedding response"
        case .apiError(let code, let message):
            return "Embedding API error (\(code)): \(message)"
        }
    }
}
