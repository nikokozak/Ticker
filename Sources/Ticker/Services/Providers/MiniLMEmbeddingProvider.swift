import CoreML
import Foundation

final class MiniLMEmbeddingProvider: EmbeddingProvider {
    enum Error: Swift.Error {
        case missingResources
        case notPrepared
        case invalidModelOutput
        case emptyEmbedding
    }

    let modelId = "sentence-transformers/all-MiniLM-L6-v2"

    private static let sequenceLength = 256
    private let resourceDirectory: URL?
    private let lock = NSLock()
    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?

    init(resourceDirectory: URL? = nil) {
        self.resourceDirectory = resourceDirectory
    }

    func prepare() async -> Bool {
        lock.withLock {
            guard model == nil else { return true }
            do {
                let directory = try resourceDirectory ?? Self.bundledResourceDirectory()
                let vocabulary = try String(contentsOf: directory.appendingPathComponent("vocab.txt"), encoding: .utf8)
                    .split(whereSeparator: \.isNewline).map(String.init)
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all
                model = try MLModel(contentsOf: directory.appendingPathComponent("MiniLM.mlmodelc"), configuration: configuration)
                tokenizer = WordPieceTokenizer(vocabulary: vocabulary, sequenceLength: Self.sequenceLength)
                return true
            } catch {
                model = nil
                tokenizer = nil
                return false
            }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try lock.withLock {
            guard let model, let tokenizer else { throw Error.notPrepared }
            return try texts.map { text in
            let encoded = tokenizer.encode(text)
            let ids = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            let types = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            for index in 0..<Self.sequenceLength {
                ids[index] = NSNumber(value: encoded.ids[index])
                mask[index] = NSNumber(value: encoded.mask[index])
                types[index] = 0
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": ids, "attention_mask": mask, "token_type_ids": types,
            ])
            guard let output = try model.prediction(from: input).featureValue(for: "token_embeddings")?.multiArrayValue,
                  output.shape.count == 3,
                  output.shape[1].intValue == Self.sequenceLength else {
                throw Error.invalidModelOutput
            }
            let dimensions = output.shape[2].intValue
            var pooled = [Double](repeating: 0, count: dimensions)
            var tokenCount = 0
            for token in 0..<Self.sequenceLength where encoded.mask[token] == 1 {
                for dimension in 0..<dimensions {
                    pooled[dimension] += output[[0, NSNumber(value: token), NSNumber(value: dimension)]].doubleValue
                }
                tokenCount += 1
            }
            guard tokenCount > 0 else { throw Error.emptyEmbedding }
            let divisor = Double(tokenCount)
            pooled = pooled.map { $0 / divisor }
            let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { throw Error.emptyEmbedding }
            return pooled.map { Float($0 / norm) }
            }
        }
    }

    private static func bundledResourceDirectory() throws -> URL {
        let root = Bundle(for: MiniLMEmbeddingProvider.self).resourceURL
        guard let url = root?.appendingPathComponent("Resources/MiniLM"),
              FileManager.default.fileExists(atPath: url.path) else { throw Error.missingResources }
        return url
    }
}

private struct WordPieceTokenizer {
    private let tokenIds: [String: Int32]
    private let sequenceLength: Int
    private let unknownId: Int32
    private let clsId: Int32
    private let sepId: Int32
    private let paddingId: Int32

    init(vocabulary: [String], sequenceLength: Int) {
        tokenIds = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, Int32($0)) })
        self.sequenceLength = sequenceLength
        unknownId = Int32(vocabulary.firstIndex(of: "[UNK]")!)
        clsId = Int32(vocabulary.firstIndex(of: "[CLS]")!)
        sepId = Int32(vocabulary.firstIndex(of: "[SEP]")!)
        paddingId = Int32(vocabulary.firstIndex(of: "[PAD]")!)
    }

    func encode(_ text: String) -> (ids: [Int32], mask: [Int32]) {
        var pieces: [Int32] = [clsId]
        for token in basicTokens(text) where pieces.count < sequenceLength - 1 {
            pieces.append(contentsOf: wordPieces(token).prefix(sequenceLength - 1 - pieces.count))
        }
        pieces.append(sepId)
        let count = pieces.count
        pieces.append(contentsOf: repeatElement(paddingId, count: sequenceLength - count))
        return (pieces, [Int32](repeating: 1, count: count) + [Int32](repeating: 0, count: sequenceLength - count))
    }

    private func basicTokens(_ text: String) -> [String] {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || scalar.properties.generalCategory == .control { continue }
            if scalar.properties.isWhitespace { cleaned.append(" "); continue }
            if isChinese(scalar) { cleaned.append(" \(scalar) ") } else { cleaned.unicodeScalars.append(scalar) }
        }
        return cleaned.split(whereSeparator: \.isWhitespace).flatMap { raw -> [String] in
            let folded = String(raw).lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            var tokens: [String] = []
            var current = ""
            for scalar in folded.unicodeScalars {
                if isPunctuation(scalar) {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    tokens.append(String(scalar))
                } else {
                    current.unicodeScalars.append(scalar)
                }
            }
            if !current.isEmpty { tokens.append(current) }
            return tokens
        }
    }

    private func wordPieces(_ token: String) -> [Int32] {
        let characters = Array(token)
        guard characters.count <= 100 else { return [unknownId] }
        var result: [Int32] = []
        var start = 0
        while start < characters.count {
            var end = characters.count
            var matched: Int32?
            while start < end {
                let piece = (start == 0 ? "" : "##") + String(characters[start..<end])
                if let id = tokenIds[piece] { matched = id; break }
                end -= 1
            }
            guard let matched else { return [unknownId] }
            result.append(matched)
            start = end
        }
        return result
    }

    private func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
        (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
            || (91...96).contains(scalar.value) || (123...126).contains(scalar.value)
            || [.connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation].contains(scalar.properties.generalCategory)
    }

    private func isChinese(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || (0x20000...0x2A6DF).contains(scalar.value) || (0x2A700...0x2B73F).contains(scalar.value)
            || (0x2B740...0x2B81F).contains(scalar.value) || (0x2B820...0x2CEAF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value) || (0x2F800...0x2FA1F).contains(scalar.value)
    }
}
