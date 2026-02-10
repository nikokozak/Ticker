import XCTest

@testable import Ticker

final class TickerNextAuthorshipSpanTransformerTests: XCTestCase {
    func test_applyUserEdit_splitSpanWhenEditingInsideAIText() {
        let original = TickerNextAuthorshipSpan(
            startUTF16: 10,
            lengthUTF16: 10,
            source: "rewrite",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let edit = TickerNextTextEdit(
            replacedRange: NSRange(location: 14, length: 2),
            insertedLength: 1
        )

        let updated = TickerNextAuthorshipSpanTransformer.applyUserEdit(spans: [original], edit: edit)

        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated[0].startUTF16, 10)
        XCTAssertEqual(updated[0].lengthUTF16, 4)
        XCTAssertEqual(updated[1].startUTF16, 15)
        XCTAssertEqual(updated[1].lengthUTF16, 4)
    }

    func test_applyUserEdit_shrinkSpanWhenEditingAcrossLeadingEdge() {
        let original = TickerNextAuthorshipSpan(
            startUTF16: 10,
            lengthUTF16: 10,
            source: "proofread",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let edit = TickerNextTextEdit(
            replacedRange: NSRange(location: 8, length: 5),
            insertedLength: 2
        )

        let updated = TickerNextAuthorshipSpanTransformer.applyUserEdit(spans: [original], edit: edit)

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].startUTF16, 10)
        XCTAssertEqual(updated[0].lengthUTF16, 7)
    }

    func test_applyUserEdit_shiftsSpansAfterEditedRange() {
        let original = TickerNextAuthorshipSpan(
            startUTF16: 20,
            lengthUTF16: 5,
            source: "summarize",
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        let edit = TickerNextTextEdit(
            replacedRange: NSRange(location: 5, length: 2),
            insertedLength: 6
        )

        let updated = TickerNextAuthorshipSpanTransformer.applyUserEdit(spans: [original], edit: edit)

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].startUTF16, 24)
        XCTAssertEqual(updated[0].lengthUTF16, 5)
    }
}

final class TickerNextDocMetadataStoreTests: XCTestCase {
    func test_saveAndLoadSpans_roundtrip() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let noteURL = tempDir.appendingPathComponent("test-note.md")
        let note = TickerMarkdownNote(
            url: noteURL,
            frontMatter: TickerNoteFrontMatter(
                tickerID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                tickerKind: .note,
                tickerPDFID: nil,
                createdAt: nil
            ),
            body: "Body"
        )

        let spans = [
            TickerNextAuthorshipSpan(
                startUTF16: 0,
                lengthUTF16: 4,
                source: "rewrite",
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            TickerNextAuthorshipSpan(
                startUTF16: 8,
                lengthUTF16: 3,
                source: "proofread",
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
        ]

        let store = TickerNextDocMetadataStore(fileManager: fileManager)
        try store.saveSpans(spans, for: note, libraryRootURL: tempDir)
        let loaded = try store.loadSpans(for: note, libraryRootURL: tempDir)

        XCTAssertEqual(loaded, spans)
    }
}
