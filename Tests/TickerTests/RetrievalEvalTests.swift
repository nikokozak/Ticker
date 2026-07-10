import Foundation
import Darwin
import XCTest

@testable import Ticker

final class RetrievalEvalTests: XCTestCase {
    func testMiniLMMatchesPythonReferenceVectors() async throws {
        let root = Self.repositoryRoot
        let references = try JSONDecoder().decode(
            ReferenceVectors.self,
            from: Data(contentsOf: root.appendingPathComponent("tools/retrieval-eval/reference-vectors.json"))
        )
        let provider = MiniLMEmbeddingProvider(
            resourceDirectory: root.appendingPathComponent("Sources/Ticker/Resources/MiniLM")
        )
        let prepared = await provider.prepare()
        guard prepared else {
            XCTFail("Bundled MiniLM resources failed to load")
            return
        }
        let actual = try await provider.embed(references.sentences.map(\.text))
        for (reference, vector) in zip(references.sentences, actual) {
            let cosine = Self.dot(reference.embedding, vector)
            print(String(format: "MiniLM fidelity cosine %.6f — %@", cosine, reference.text))
            XCTAssertGreaterThanOrEqual(cosine, 0.999, reference.text)
        }
    }

    func testBM25Baseline() throws {
        let root = Self.repositoryRoot
        // ponytail: A repo-local marker is process-global; use a per-run test plan if concurrent eval lanes ever matter.
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/retrieval-eval-enabled").path) else {
            throw XCTSkip("Manual lane: ./tickerctl.sh eval-retrieval")
        }

        let goldenURL = root.appendingPathComponent("tools/retrieval-eval/golden.json")
        let outputURL = root.appendingPathComponent("tools/retrieval-eval/baseline.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
        let bm25 = try Self.bm25Results(golden: golden)
        let cases = golden.cases.map { item -> CaseResult in
            let retrieved = bm25[item.id, default: []]
            let found = item.expected.filter(Set(retrieved).contains).count
            return CaseResult(
                id: item.id,
                className: item.className,
                expected: item.expected,
                retrieved: retrieved,
                recall: item.expected.isEmpty ? (retrieved.isEmpty ? 1 : 0) : Double(found) / Double(item.expected.count)
            )
        }
        let report = Report(cases: cases)
        print(report.table)
        try Self.validateKnownFailures(golden: golden, report: report)
        try JSONEncoder.pretty.encode(report).write(to: outputURL, options: .atomic)
        try (report.table + "\n").write(to: outputURL.appendingPathExtension("table"), atomically: true, encoding: .utf8)
    }

    func testHybridSweep() async throws {
        let root = Self.repositoryRoot
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/retrieval-eval-enabled").path) else {
            throw XCTSkip("Manual lane: ./tickerctl.sh eval-retrieval")
        }

        let golden = try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: root.appendingPathComponent("tools/retrieval-eval/golden.json"))
        )
        let provider = MiniLMEmbeddingProvider(
            resourceDirectory: root.appendingPathComponent("Sources/Ticker/Resources/MiniLM")
        )

        let memoryBefore = Self.physicalFootprintBytes()
        let loadStart = ContinuousClock.now
        let prepared = await provider.prepare()
        let modelLoadMs = Self.milliseconds(loadStart.duration(to: .now))
        let memoryAfter = Self.physicalFootprintBytes()
        guard prepared else {
            XCTFail("Bundled MiniLM resources failed to load")
            return
        }

        let bm25 = try Self.bm25Results(golden: golden)
        let coldStart = ContinuousClock.now
        _ = try await provider.embed([golden.cases[0].query])
        let coldQueryMs = Self.milliseconds(coldStart.duration(to: .now))
        let corpusVectors = try await provider.embed(golden.corpus.map(\.text))
        var queryVectors: [String: [Float]] = [:]
        var latenciesMs: [Double] = []
        for item in golden.cases {
            let start = ContinuousClock.now
            queryVectors[item.id] = try await provider.embed([item.query])[0]
            latenciesMs.append(Self.milliseconds(start.duration(to: .now)))
        }

        let floors = stride(from: 0.00, through: 1.00, by: 0.025).map { ($0 * 1_000).rounded() / 1_000 }
        let sweeps = floors.map { floor in
            SweepResult(floor: floor, report: Self.hybridReport(
                golden: golden, bm25: bm25, corpusVectors: corpusVectors,
                queryVectors: queryVectors, cosineFloor: Float(floor)
            ))
        }
        let separation = Self.separation(golden: golden, corpusVectors: corpusVectors, queryVectors: queryVectors)
        let requiredFloor = Double(separation.bestUnrelatedCosine) + 0.05
        guard let selected = sweeps.first(where: { $0.floor >= requiredFloor }) else {
            XCTFail("No swept floor satisfies best unrelated cosine + 0.05")
            return
        }
        XCTAssertEqual(selected.report.metrics["lexical"]?.recallAt8, 1)
        try Self.validateKnownFailures(golden: golden, report: selected.report)
        let sensitivity = [-0.05, 0, 0.05].compactMap { delta in
            sweeps.first { abs($0.floor - selected.floor - delta) < 0.0001 }.map(SensitivityRow.init)
        }

        let latency = Latency(
            p50Ms: Self.percentile(latenciesMs, 0.50),
            p95Ms: Self.percentile(latenciesMs, 0.95)
        )
        let operatingPoint = OperatingPoint(
            provider: "MiniLMEmbeddingProvider",
            modelId: provider.modelId,
            cosineFloor: selected.floor,
            rrfK: 60,
            topK: 8,
            latency: Performance(modelLoadMs: modelLoadMs, coldQueryMs: coldQueryMs, warmQueryMs: latency),
            memory: Memory(
                beforePrepareBytes: memoryBefore,
                afterPrepareBytes: memoryAfter,
                deltaBytes: Int64(memoryAfter) - Int64(memoryBefore)
            ),
            separation: separation,
            marginRule: MarginRule(
                bestObservedUnrelatedCosine: Double(separation.bestUnrelatedCosine),
                requiredMargin: 0.05,
                minimumFloor: requiredFloor,
                gridStep: 0.025,
                chosenFloor: selected.floor,
                achievedMargin: selected.floor - Double(separation.bestUnrelatedCosine)
            ),
            sensitivity: sensitivity,
            sweep: sweeps.map(SweepRow.init)
        )
        let outputRoot = root.appendingPathComponent("tools/retrieval-eval")
        try JSONEncoder.pretty.encode(operatingPoint).write(to: outputRoot.appendingPathComponent("operating-point.json"), options: .atomic)
        try JSONEncoder.pretty.encode(selected.report).write(to: outputRoot.appendingPathComponent("hybrid.json"), options: .atomic)
        try (selected.report.table + "\n").write(
            to: outputRoot.appendingPathComponent("hybrid.json.table"), atomically: true, encoding: .utf8
        )
        print(selected.report.table)
    }

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private static func bm25Results(golden: Golden) throws -> [String: [String]] {
        let fileManager = FileManager.default
        return try Dictionary(uniqueKeysWithValues: golden.cases.map { item in
            let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }
            let persistence = try PersistenceService(
                databaseURL: directory.appendingPathComponent("ticker.db"), fileManager: fileManager
            )
            let stream = Stream(id: uuid(0), title: "Retrieval Eval", createdAt: .distantPast, updatedAt: .distantPast)
            try persistence.saveStream(stream)
            var productionToGolden: [UUID: String] = [:]
            for (sourceIndex, group) in Dictionary(grouping: golden.corpus(for: item), by: \.sourceName)
                .sorted(by: { $0.key < $1.key }).enumerated() {
                let source = SourceReference(
                    id: uuid(sourceIndex + 1), streamId: stream.id, displayName: group.key,
                    fileType: .pdf, bookmarkData: Data(), status: .ready, indexStatus: .ready, addedAt: .distantPast
                )
                try persistence.saveSource(source)
                let chunks = group.value.sorted(by: { $0.id < $1.id }).enumerated().map { offset, chunk in
                    let id = uuid(1_000 + productionToGolden.count)
                    productionToGolden[id] = chunk.id
                    return SourceChunk(
                        id: id, sourceId: source.id, seq: offset, text: chunk.text,
                        pageStart: chunk.pageStart, pageEnd: chunk.pageEnd, sectionPath: chunk.sectionPath.nilIfEmpty
                    )
                }
                try persistence.saveSourceChunks(chunks, for: source.id)
            }
            let retrieved = try RetrievalService(persistence: persistence)
                .retrieve(query: item.query, streamId: stream.id).compactMap { productionToGolden[$0.id] }
            return (item.id, retrieved)
        })
    }

    private static func hybridReport(
        golden: Golden,
        bm25: [String: [String]],
        corpusVectors: [[Float]],
        queryVectors: [String: [Float]],
        cosineFloor: Float
    ) -> Report {
        let cases = golden.cases.map { item -> CaseResult in
            let query = queryVectors[item.id]!
            var scored: [(id: String, score: Float)] = []
            for index in golden.corpus.indices where golden.includes(golden.corpus[index], for: item) {
                scored.append((golden.corpus[index].id, dot(query, corpusVectors[index])))
            }
            let passing = scored.filter { $0.score >= cosineFloor }
            let ranked = passing.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            let semantic = ranked.map(\.id)
            let retrieved = RetrievalService.reciprocalRankFuse(
                bm25: bm25[item.id, default: []], semantic: semantic, rrfK: 60, limit: 8
            )
            let found = item.expected.filter(Set(retrieved).contains).count
            return CaseResult(
                id: item.id, className: item.className, expected: item.expected, retrieved: retrieved,
                recall: item.expected.isEmpty ? (retrieved.isEmpty ? 1 : 0) : Double(found) / Double(item.expected.count)
            )
        }
        return Report(mode: "hybrid", cases: cases)
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func validateKnownFailures(golden: Golden, report: Report) throws {
        let annotations = Dictionary(uniqueKeysWithValues: golden.cases.compactMap { item in
            item.knownFailure.map { (item.id, $0) }
        })
        for result in report.cases {
            let passed = result.recall == 1
            if let note = annotations[result.id] {
                if passed {
                    XCTFail("recovered — remove annotation: \(result.id) — \(note)")
                } else {
                    print("KNOWN FAIL: \(result.id) — \(note)")
                }
            }
        }
    }

    private static func separation(
        golden: Golden,
        corpusVectors: [[Float]],
        queryVectors: [String: [Float]]
    ) -> Separation {
        let corpusIndex = Dictionary(uniqueKeysWithValues: golden.corpus.enumerated().map { ($1.id, $0) })
        let relevant = golden.cases.flatMap { item in
            item.expected.compactMap { expected in
                corpusIndex[expected].map { dot(queryVectors[item.id]!, corpusVectors[$0]) }
            }
        }
        let unrelated = golden.cases.filter { $0.expected.isEmpty }.flatMap { item in
            golden.corpus.indices.compactMap { index in
                golden.includes(golden.corpus[index], for: item)
                    ? dot(queryVectors[item.id]!, corpusVectors[index]) : nil
            }
        }
        let worstRelevant = relevant.min() ?? 0
        let bestUnrelated = unrelated.max() ?? 0
        return Separation(
            bestUnrelatedCosine: Double(bestUnrelated),
            worstRelevantCosine: Double(worstRelevant),
            margin: Double(worstRelevant - bestUnrelated)
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        let index = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[max(0, index)]
    }

    private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

private struct ReferenceVectors: Decodable {
    let sentences: [ReferenceSentence]
}

private struct ReferenceSentence: Decodable {
    let text: String
    let embedding: [Float]
}

private struct Golden: Decodable {
    let corpus: [CorpusChunk]
    let cases: [GoldenCase]

    func corpus(for item: GoldenCase) -> [CorpusChunk] {
        corpus.filter { includes($0, for: item) }
    }

    func includes(_ chunk: CorpusChunk, for item: GoldenCase) -> Bool {
        item.corpusFilter?.contains { chunk.id.hasPrefix($0) } ?? true
    }
}

private struct CorpusChunk: Decodable {
    let id: String
    let sourceName: String
    let pageStart: Int
    let pageEnd: Int
    let sectionPath: String
    let text: String
}

private struct GoldenCase: Decodable {
    let id: String
    let className: String
    let query: String
    let expected: [String]
    let corpusFilter: [String]?
    let knownFailure: String?

    enum CodingKeys: String, CodingKey {
        case id, query, expected, corpusFilter, knownFailure
        case className = "class"
    }
}

private struct CaseResult: Encodable {
    let id: String
    let className: String
    let expected: [String]
    let retrieved: [String]
    let recall: Double

    enum CodingKeys: String, CodingKey {
        case id, expected, retrieved, recall
        case className = "class"
    }
}

private struct Metric: Encodable {
    let cases: Int
    let recallAt8: Double
}

private struct Report: Encodable {
    let version = 1
    let mode: String
    let metrics: [String: Metric]
    let negativeFalseRetrievalRate: Double
    let cases: [CaseResult]

    init(mode: String = "bm25", cases: [CaseResult]) {
        self.mode = mode
        self.cases = cases
        let grouped = Dictionary(grouping: cases, by: \.className)
        var metrics = grouped.mapValues(Self.metric)
        metrics["overall"] = Self.metric(cases)
        self.metrics = metrics
        let negatives = grouped["negative", default: []]
        negativeFalseRetrievalRate = negatives.isEmpty ? 0 : Double(negatives.filter { !$0.retrieved.isEmpty }.count) / Double(negatives.count)
    }

    var table: String {
        let rows = ["paraphrase", "lexical", "negative", "overall"].compactMap { name -> String? in
            guard let metric = metrics[name] else { return nil }
            return "\(name.padding(toLength: 10, withPad: " ", startingAt: 0))  \(String(format: "%5d %8.1f%%", metric.cases, metric.recallAt8 * 100))"
        }
        return ([
            "class       cases  recall@8",
            "----------  -----  --------"
        ] + rows + [String(format: "negative false-retrieval rate: %.1f%%", negativeFalseRetrievalRate * 100)]).joined(separator: "\n")
    }

    private static func metric(_ cases: [CaseResult]) -> Metric {
        Metric(cases: cases.count, recallAt8: cases.map(\.recall).reduce(0, +) / Double(cases.count))
    }
}

private struct Latency: Encodable {
    let p50Ms: Double
    let p95Ms: Double
}

private struct Memory: Encodable {
    let beforePrepareBytes: UInt64
    let afterPrepareBytes: UInt64
    let deltaBytes: Int64
}

private struct Performance: Encodable {
    let modelLoadMs: Double
    let coldQueryMs: Double
    let warmQueryMs: Latency
}

private struct Separation: Encodable {
    let bestUnrelatedCosine: Double
    let worstRelevantCosine: Double
    let margin: Double
}

private struct MarginRule: Encodable {
    let bestObservedUnrelatedCosine: Double
    let requiredMargin: Double
    let minimumFloor: Double
    let gridStep: Double
    let chosenFloor: Double
    let achievedMargin: Double
}

private struct SweepResult {
    let floor: Double
    let report: Report
}

private struct SweepRow: Encodable {
    let cosineFloor: Double
    let paraphraseRecallAt8: Double
    let lexicalRecallAt8: Double
    let negativeFalseRetrievalRate: Double

    init(_ result: SweepResult) {
        cosineFloor = result.floor
        paraphraseRecallAt8 = result.report.metrics["paraphrase"]?.recallAt8 ?? 0
        lexicalRecallAt8 = result.report.metrics["lexical"]?.recallAt8 ?? 0
        negativeFalseRetrievalRate = result.report.negativeFalseRetrievalRate
    }
}

private struct SensitivityRow: Encodable {
    let cosineFloor: Double
    let paraphraseRecallAt8: Double
    let lexicalRecallAt8: Double
    let negativeFalseRetrievalRate: Double

    init(_ result: SweepResult) {
        cosineFloor = result.floor
        paraphraseRecallAt8 = result.report.metrics["paraphrase"]?.recallAt8 ?? 0
        lexicalRecallAt8 = result.report.metrics["lexical"]?.recallAt8 ?? 0
        negativeFalseRetrievalRate = result.report.negativeFalseRetrievalRate
    }
}

private struct OperatingPoint: Encodable {
    let version = 2
    let provider: String
    let modelId: String
    let cosineFloor: Double
    let rrfK: Int
    let topK: Int
    let latency: Performance
    let memory: Memory
    let separation: Separation
    let marginRule: MarginRule
    let sensitivity: [SensitivityRow]
    let sweep: [SweepRow]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
