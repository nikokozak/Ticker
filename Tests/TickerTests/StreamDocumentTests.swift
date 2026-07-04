import Foundation
import XCTest

@testable import Ticker

final class StreamDocumentTests: XCTestCase {
    func test_appendToStreamDocument_createsDocumentWithExactlyFragmentWhenMissing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "New Document")
            try service.saveStream(stream)

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "Captured note")

            XCTAssertEqual(result.fragment, "Captured note")
            XCTAssertTrue(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Captured note")
        }
    }

    func test_appendToStreamDocument_appendsWithBlankLineSeparatorWhenDocumentExists() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Existing Document")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "Existing markdown")

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "New fragment")

            XCTAssertEqual(result.fragment, "New fragment")
            XCTAssertFalse(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Existing markdown\n\nNew fragment")
        }
    }

    func test_appendToStreamDocument_skipsSeparatorWhenExistingDocumentIsEmpty() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Empty Existing Document")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "")

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "Only fragment")

            XCTAssertEqual(result.fragment, "Only fragment")
            XCTAssertFalse(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Only fragment")
        }
    }

    func test_appendToStreamDocument_twoSequentialAppendsPreserveOrder() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Sequential Appends")
            try service.saveStream(stream)

            let first = try service.appendToStreamDocument(streamId: stream.id, fragment: "First fragment")
            let second = try service.appendToStreamDocument(streamId: stream.id, fragment: "Second fragment")

            XCTAssertTrue(first.isNewDocument)
            XCTAssertFalse(second.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "First fragment\n\nSecond fragment")
        }
    }

    func test_loadOrCreateStreamDocumentAfterAppendReturnsMarkdownContainingFragment() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Load After Append")
            try service.saveStream(stream)

            _ = try service.appendToStreamDocument(streamId: stream.id, fragment: "Visible capture")

            let document = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertTrue(document.markdown.contains("Visible capture"))
        }
    }

    func test_appendToStreamDocument_bumpsDocumentAndStreamUpdatedAt() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Timestamp Bump")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "Before")

            let beforeDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let beforeStream = try XCTUnwrap(service.loadStream(id: stream.id))

            Thread.sleep(forTimeInterval: 0.01)

            _ = try service.appendToStreamDocument(streamId: stream.id, fragment: "After")

            let afterDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let afterStream = try XCTUnwrap(service.loadStream(id: stream.id))

            XCTAssertGreaterThan(
                afterDocument.updatedAt.timeIntervalSince1970,
                beforeDocument.updatedAt.timeIntervalSince1970
            )
            XCTAssertGreaterThan(
                afterStream.updatedAt.timeIntervalSince1970,
                beforeStream.updatedAt.timeIntervalSince1970
            )
        }
    }

    func test_appendToStreamDocumentSeedsLegacyCellsBeforeAppendingWhenDocumentMissing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Legacy Seed")
            try service.saveStream(stream)

            let legacyCell = Cell(
                streamId: stream.id,
                content: "<p>Legacy note</p>",
                type: .text,
                order: 0
            )
            try service.saveCell(legacyCell)

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "New capture")

            XCTAssertEqual(result.fragment, "New capture")
            XCTAssertTrue(result.isNewDocument)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Legacy note\n\nNew capture")

            let loaded = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(loaded.markdown, "Legacy note\n\nNew capture")
        }
    }

    private func withTempPersistenceService(_ body: (PersistenceService) throws -> Void) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        defer {
            service = nil
            _ = try? fileManager.removeItem(at: tempDir)
        }

        guard let service else {
            XCTFail("Expected persistence service")
            return
        }

        try body(service)
    }
}
