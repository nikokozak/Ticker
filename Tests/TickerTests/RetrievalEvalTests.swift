import Foundation
import Darwin
import XCTest

@testable import Ticker

final class RetrievalEvalTests: XCTestCase {
    func testBM25Baseline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // ponytail: A repo-local marker is process-global; use a per-run test plan if concurrent eval lanes ever matter.
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/retrieval-eval-enabled").path) else {
            throw XCTSkip("Manual lane: ./tickerctl.sh eval-retrieval")
        }

        let goldenURL = root.appendingPathComponent("tools/retrieval-eval/golden.json")
        let outputURL = root.appendingPathComponent("tools/retrieval-eval/baseline.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let persistence = try PersistenceService(
            databaseURL: tempDirectory.appendingPathComponent("ticker.db"),
            fileManager: fileManager
        )
        let stream = Stream(id: Self.uuid(0), title: "Retrieval Eval", createdAt: .distantPast, updatedAt: .distantPast)
        try persistence.saveStream(stream)

        var productionToGolden: [UUID: String] = [:]
        for (sourceIndex, group) in Dictionary(grouping: golden.corpus, by: \.sourceName)
            .sorted(by: { $0.key < $1.key }).enumerated() {
            let source = SourceReference(
                id: Self.uuid(sourceIndex + 1),
                streamId: stream.id,
                displayName: group.key,
                fileType: .pdf,
                bookmarkData: Data(),
                status: .ready,
                indexStatus: .ready,
                addedAt: .distantPast
            )
            try persistence.saveSource(source)
            let chunks = group.value.sorted(by: { $0.id < $1.id }).enumerated().map { offset, item in
                let id = Self.uuid(1_000 + productionToGolden.count)
                productionToGolden[id] = item.id
                return SourceChunk(
                    id: id,
                    sourceId: source.id,
                    seq: offset,
                    text: item.text,
                    pageStart: item.pageStart,
                    pageEnd: item.pageEnd,
                    sectionPath: item.sectionPath.nilIfEmpty
                )
            }
            try persistence.saveSourceChunks(chunks, for: source.id)
        }

        let retrieval = RetrievalService(persistence: persistence)
        let cases = try golden.cases.map { item -> CaseResult in
            let retrieved = try retrieval.retrieve(query: item.query, streamId: stream.id)
                .compactMap { productionToGolden[$0.id] }
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
        try JSONEncoder.pretty.encode(report).write(to: outputURL, options: .atomic)
        try (report.table + "\n").write(to: outputURL.appendingPathExtension("table"), atomically: true, encoding: .utf8)
    }

    func testHybridSweep() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/retrieval-eval-enabled").path) else {
            throw XCTSkip("Manual lane: ./tickerctl.sh eval-retrieval")
        }

        let golden = try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: root.appendingPathComponent("tools/retrieval-eval/golden.json"))
        )
        guard let provider = NaturalLanguageEmbeddingProvider() else {
            XCTFail("NLContextualEmbedding has no English model on this OS")
            return
        }

        let memoryBefore = Self.physicalFootprintBytes()
        let prepared = await provider.prepare()
        let memoryAfter = Self.physicalFootprintBytes()
        guard prepared else {
            let unavailable = OperatingPoint.unavailable(
                modelId: provider.modelId,
                assetsPreinstalled: provider.assetsWereAvailableBeforePrepare,
                memoryBefore: memoryBefore,
                memoryAfter: memoryAfter
            )
            try JSONEncoder.pretty.encode(unavailable).write(
                to: root.appendingPathComponent("tools/retrieval-eval/operating-point.json"), options: .atomic
            )
            throw XCTSkip("NLContextualEmbedding assets unavailable; see operating-point.json")
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }
        let persistence = try PersistenceService(
            databaseURL: tempDirectory.appendingPathComponent("ticker.db"),
            fileManager: fileManager
        )
        let stream = Stream(id: Self.uuid(0), title: "Retrieval Eval", createdAt: .distantPast, updatedAt: .distantPast)
        try persistence.saveStream(stream)

        var productionToGolden: [UUID: String] = [:]
        for (sourceIndex, group) in Dictionary(grouping: golden.corpus, by: \.sourceName)
            .sorted(by: { $0.key < $1.key }).enumerated() {
            let source = SourceReference(
                id: Self.uuid(sourceIndex + 1), streamId: stream.id, displayName: group.key,
                fileType: .pdf, bookmarkData: Data(), status: .ready, indexStatus: .ready, addedAt: .distantPast
            )
            try persistence.saveSource(source)
            let chunks = group.value.sorted(by: { $0.id < $1.id }).enumerated().map { offset, item in
                let id = Self.uuid(1_000 + productionToGolden.count)
                productionToGolden[id] = item.id
                return SourceChunk(
                    id: id, sourceId: source.id, seq: offset, text: item.text,
                    pageStart: item.pageStart, pageEnd: item.pageEnd, sectionPath: item.sectionPath.nilIfEmpty
                )
            }
            try persistence.saveSourceChunks(chunks, for: source.id)
        }

        let retrieval = RetrievalService(persistence: persistence)
        let bm25 = try Dictionary(uniqueKeysWithValues: golden.cases.map { item in
            let ids = try retrieval.retrieve(query: item.query, streamId: stream.id)
                .compactMap { productionToGolden[$0.id] }
            return (item.id, ids)
        })
        let corpusVectors = try await provider.embed(golden.corpus.map(\.text))
        var queryVectors: [String: [Float]] = [:]
        var latenciesMs: [Double] = []
        for item in golden.cases {
            let start = ContinuousClock.now
            queryVectors[item.id] = try await provider.embed([item.query])[0]
            let elapsed = start.duration(to: .now).components
            latenciesMs.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }

        let floors = stride(from: 0.25, through: 1.00, by: 0.025).map { ($0 * 1_000).rounded() / 1_000 }
        let sweeps = floors.map { floor in
            SweepResult(floor: floor, report: Self.hybridReport(
                golden: golden, bm25: bm25, corpusVectors: corpusVectors,
                queryVectors: queryVectors, cosineFloor: Float(floor)
            ))
        }
        let eligible = sweeps.filter {
            $0.report.metrics["lexical"]?.recallAt8 ?? 0 >= 1
                && $0.report.negativeFalseRetrievalRate == 0
        }
        guard let selected = eligible.max(by: {
            let lhs = $0.report.metrics["paraphrase"]?.recallAt8 ?? 0
            let rhs = $1.report.metrics["paraphrase"]?.recallAt8 ?? 0
            return lhs == rhs ? $0.floor < $1.floor : lhs < rhs
        }) else {
            XCTFail("No cosine floor preserved lexical recall and zero negative false retrievals")
            return
        }

        let latency = Latency(
            p50Ms: Self.percentile(latenciesMs, 0.50),
            p95Ms: Self.percentile(latenciesMs, 0.95)
        )
        let operatingPoint = OperatingPoint(
            modelId: provider.modelId,
            assetsPreinstalled: provider.assetsWereAvailableBeforePrepare,
            assetsAvailable: true,
            cosineFloor: selected.floor,
            rrfK: 60,
            topK: 8,
            queryEmbedLatencyMs: latency,
            memory: Memory(beforePrepareBytes: memoryBefore, afterPrepareBytes: memoryAfter),
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
            for index in golden.corpus.indices {
                scored.append((golden.corpus[index].id, dot(query, corpusVectors[index])))
            }
            let passing = scored.filter { $0.score >= cosineFloor }
            let ranked = passing.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            let semantic = ranked.map(\.id)
            var fused: [String: Double] = [:]
            for (offset, id) in bm25[item.id, default: []].enumerated() {
                fused[id, default: 0] += 1 / Double(60 + offset + 1)
            }
            for (offset, id) in semantic.enumerated() {
                fused[id, default: 0] += 1 / Double(60 + offset + 1)
            }
            let retrieved = fused.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(8).map(\.key)
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
}

private struct Golden: Decodable {
    let corpus: [CorpusChunk]
    let cases: [GoldenCase]
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

    enum CodingKeys: String, CodingKey {
        case id, query, expected
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

private struct OperatingPoint: Encodable {
    let version = 1
    let modelId: String
    let assetsPreinstalled: Bool
    let assetsAvailable: Bool
    let cosineFloor: Double?
    let rrfK: Int
    let topK: Int
    let queryEmbedLatencyMs: Latency?
    let memory: Memory
    let sweep: [SweepRow]

    static func unavailable(
        modelId: String,
        assetsPreinstalled: Bool,
        memoryBefore: UInt64,
        memoryAfter: UInt64
    ) -> Self {
        Self(
            modelId: modelId, assetsPreinstalled: assetsPreinstalled, assetsAvailable: false,
            cosineFloor: nil, rrfK: 60, topK: 8, queryEmbedLatencyMs: nil,
            memory: Memory(beforePrepareBytes: memoryBefore, afterPrepareBytes: memoryAfter), sweep: []
        )
    }
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
