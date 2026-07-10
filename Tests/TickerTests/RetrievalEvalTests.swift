import Foundation
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

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
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
    let mode = "bm25"
    let metrics: [String: Metric]
    let negativeFalseRetrievalRate: Double
    let cases: [CaseResult]

    init(cases: [CaseResult]) {
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
