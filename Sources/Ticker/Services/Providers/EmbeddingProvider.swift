import Foundation
import NaturalLanguage

protocol EmbeddingProvider {
    var modelId: String { get }
    func prepare() async -> Bool
    func embed(_ texts: [String]) async throws -> [[Float]]
}

final class NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    enum Error: Swift.Error {
        case notPrepared
        case emptyEmbedding
    }

    let assetsWereAvailableBeforePrepare: Bool
    var modelId: String { model.modelIdentifier }

    private let model: NLContextualEmbedding
    private var isPrepared = false

    init?(language: NLLanguage = .english) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        assetsWereAvailableBeforePrepare = model.hasAvailableAssets
    }

    func prepare() async -> Bool {
        guard !isPrepared else { return true }
        do {
            if !model.hasAvailableAssets, try await model.requestAssets() != .available {
                return false
            }
            try model.load()
            isPrepared = true
            return true
        } catch {
            return false
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard isPrepared else { throw Error.notPrepared }
        return try texts.map { text in
            let result = try model.embeddingResult(for: text, language: .english)
            var sum = [Double](repeating: 0, count: model.dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for index in vector.indices { sum[index] += vector[index] }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else { throw Error.emptyEmbedding }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { throw Error.emptyEmbedding }
            return sum.map { Float($0 / norm) }
        }
    }
}
