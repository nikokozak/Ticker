import CoreGraphics
import AppKit
import Darwin
import Foundation
import GRDB
import PDFKit
import XCTest

@testable import Ticker

final class BridgeDateParsingTests: XCTestCase {
    func test_acceptsBrowserISODateWithFractionalSeconds() throws {
        let date = try XCTUnwrap(StreamMessageHandler.dateValue("2026-07-31T20:28:18.123Z"))

        XCTAssertEqual(date.timeIntervalSince1970, 1_785_529_698.123, accuracy: 0.001)
    }
}

final class TickerURLCommandTests: XCTestCase {
    func test_parseAppendURL() throws {
        let url = try XCTUnwrap(URL(string: "ticker://append?stream=Notebook&text=hello%20world"))

        XCTAssertEqual(
            TickerURLCommand.parse(url),
            .append(stream: .title("Notebook"), text: "hello world")
        )
    }

    func test_parseOpenURL() throws {
        let streamId = UUID()
        let url = try XCTUnwrap(URL(string: "ticker://open?stream=\(streamId.uuidString)"))

        XCTAssertEqual(TickerURLCommand.parse(url), .open(streamId: streamId))
    }

    func test_parseAppendURLMissingParamsReturnsNil() throws {
        XCTAssertNil(TickerURLCommand.parse(try XCTUnwrap(URL(string: "ticker://append?stream=Notebook"))))
        XCTAssertNil(TickerURLCommand.parse(try XCTUnwrap(URL(string: "ticker://append?text=hello"))))
    }

    func test_parseOpenURLBadUUIDReturnsNil() throws {
        XCTAssertNil(TickerURLCommand.parse(try XCTUnwrap(URL(string: "ticker://open?stream=not-a-uuid"))))
    }

    func test_parseAppendURLOverCapReturnsNil() throws {
        var components = URLComponents()
        components.scheme = "ticker"
        components.host = "append"
        components.queryItems = [
            URLQueryItem(name: "stream", value: "Notebook"),
            URLQueryItem(name: "text", value: String(repeating: "a", count: TickerURLCommand.maxAppendTextLength + 1))
        ]

        XCTAssertNil(TickerURLCommand.parse(try XCTUnwrap(components.url)))
    }
}

private final class TestEmbeddingProvider: EmbeddingProvider {
    let modelId = "test-model"
    private let embedBlock: ([String]) throws -> [[Float]]

    init(embed: @escaping ([String]) throws -> [[Float]]) {
        embedBlock = embed
    }

    var isReady: Bool { true }
    func prepare() async -> Bool { true }
    func embed(_ texts: [String]) async throws -> [[Float]] { try embedBlock(texts) }
}

final class QuickPanelMarkdownFormatterTests: XCTestCase {
    func test_buildFragment_includesSelectedTextAsBlockquoteWithAttribution() throws {
        let context = QuickPanelContext(
            selectedText: " First line\nSecond line ",
            activeApp: "Safari",
            windowTitle: "Article *Title*",
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil
        )

        let fragment = try QuickPanelMarkdownFormatter.buildFragment(
            context: context,
            inputText: "Saved note"
        ) { _ in
            XCTFail("Image formatter should not run for text-only context")
            return ""
        }

        XCTAssertEqual(fragment, """
        > First line
        > Second line

        *— Safari — Article \\*Title\\**

        Saved note
        """)
    }

    func test_buildFragment_usesClipboardTextAsBlockquoteContext() throws {
        let context = QuickPanelContext(
            selectedText: nil,
            activeApp: "Terminal",
            windowTitle: "Shell",
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil,
            clipboardText: " Copied line "
        )

        let fragment = try QuickPanelMarkdownFormatter.buildFragment(
            context: context,
            inputText: ""
        ) { _ in
            XCTFail("Image formatter should not run for text-only context")
            return ""
        }

        XCTAssertEqual(context.contextText, "Copied line")
        XCTAssertTrue(context.isClipboardTextContext)
        XCTAssertEqual(fragment, """
        > Copied line

        *— Terminal — Shell*
        """)
    }

    func test_captureSpansCoverCapturedTextAndAttributionOnly() throws {
        let streamId = UUID()
        let context = QuickPanelContext(
            selectedText: " First line\nSecond line ",
            activeApp: "Safari",
            windowTitle: "Article *Title*",
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil
        )
        let fragment = try QuickPanelMarkdownFormatter.buildFragment(
            context: context,
            inputText: "Saved note"
        ) { _ in
            XCTFail("Image formatter should not run for text-only context")
            return ""
        }

        let spans = QuickPanelMarkdownFormatter.captureSpans(context: context, fragment: fragment, streamId: streamId)

        let captured = """
        > First line
        > Second line

        *— Safari — Article \\*Title\\**
        """
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].streamId, streamId)
        XCTAssertEqual(spans[0].start, 0)
        XCTAssertEqual(spans[0].end, UTF16Offsets.utf16Length(captured))
        XCTAssertEqual(spans[0].origin, "capture")
        XCTAssertEqual(spans[0].meta, #"{"sourceApp":"Safari"}"#)
        XCTAssertEqual(spans[0].textHash, FNV1a.hash(captured))
    }

    func test_recentClipboardTextCandidateReturnsRecentPlainText() throws {
        let pasteboard = makeTrackedPasteboard()
        defer { pasteboard.clearContents() }

        writeText(" Copied text ", to: pasteboard)

        XCTAssertEqual(
            SelectionReaderService.recentClipboardTextCandidate(pasteboard: pasteboard),
            "Copied text"
        )
    }

    func test_recentClipboardTextCandidateRejectsStaleEmptyAndPrivateText() throws {
        let stalePasteboard = makeTrackedPasteboard()
        defer { stalePasteboard.clearContents() }
        writeText("Stale text", to: stalePasteboard)
        ClipboardService.syncChangeCount(pasteboard: stalePasteboard)
        XCTAssertNil(SelectionReaderService.recentClipboardTextCandidate(pasteboard: stalePasteboard))

        let emptyPasteboard = makeTrackedPasteboard()
        defer { emptyPasteboard.clearContents() }
        writeText(" \n\t ", to: emptyPasteboard)
        XCTAssertNil(SelectionReaderService.recentClipboardTextCandidate(pasteboard: emptyPasteboard))

        let concealedPasteboard = makeTrackedPasteboard()
        defer { concealedPasteboard.clearContents() }
        writeText("Password", to: concealedPasteboard, extraTypes: [ClipboardService.concealedType])
        XCTAssertNil(SelectionReaderService.recentClipboardTextCandidate(pasteboard: concealedPasteboard))

        let transientPasteboard = makeTrackedPasteboard()
        defer { transientPasteboard.clearContents() }
        writeText("Transient", to: transientPasteboard, extraTypes: [ClipboardService.transientType])
        XCTAssertNil(SelectionReaderService.recentClipboardTextCandidate(pasteboard: transientPasteboard))
    }

    func test_recentClipboardTextCandidateTruncatesLongText() throws {
        let pasteboard = makeTrackedPasteboard()
        defer { pasteboard.clearContents() }
        writeText(String(repeating: "x", count: 10_005), to: pasteboard)

        let result = try XCTUnwrap(SelectionReaderService.recentClipboardTextCandidate(pasteboard: pasteboard))

        XCTAssertEqual(result.count, 10_001)
        XCTAssertEqual(result.last, "…")
        XCTAssertEqual(result.dropLast().count, 10_000)
    }

    func test_clipboardSyncChangeCountIgnoresSyntheticCopyRestoreBumps() throws {
        let pasteboard = makeTrackedPasteboard()
        defer { pasteboard.clearContents() }
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        writeText("Synthetic copy", to: pasteboard)
        snapshot.restore(to: pasteboard)
        ClipboardService.syncChangeCount(pasteboard: pasteboard)

        XCTAssertFalse(ClipboardService.wasRecentlyModified(threshold: 15, pasteboard: pasteboard))

        writeText("Genuine copy", to: pasteboard)
        XCTAssertTrue(ClipboardService.wasRecentlyModified(threshold: 15, pasteboard: pasteboard))
    }

    func test_buildContextPrefersSelectionOverClipboardText() {
        let context = SelectionReaderService().buildContext(
            selectedText: " Selected text ",
            clipboardTextCandidate: "Copied text",
            readSelectionFromAX: false
        )

        XCTAssertEqual(context.contextText, "Selected text")
        XCTAssertNil(context.clipboardText)
        XCTAssertTrue(context.hasSelection)
        XCTAssertFalse(context.isClipboardTextContext)
    }

    @MainActor
    func test_clipboardTextDismissSuppressionSkipsSameChangeCountOnly() {
        let context = QuickPanelContext(
            selectedText: nil,
            activeApp: "Terminal",
            windowTitle: nil,
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil,
            clipboardText: "Copied text"
        )
        var suppressedChangeCount: Int? = 7

        let sameCopy = QuickPanelManager.contextRespectingDismissedClipboardText(
            context,
            suppressedChangeCount: &suppressedChangeCount,
            currentClipboardChangeCount: 7
        )
        XCTAssertNil(sameCopy.clipboardText)
        XCTAssertEqual(suppressedChangeCount, 7)

        let newCopy = QuickPanelManager.contextRespectingDismissedClipboardText(
            context,
            suppressedChangeCount: &suppressedChangeCount,
            currentClipboardChangeCount: 8
        )
        XCTAssertEqual(newCopy.clipboardText, "Copied text")
        XCTAssertNil(suppressedChangeCount)
    }

    @MainActor
    func test_clipboardTextContextExpiresOnlyWhileIdle() {
        let clipboardContext = QuickPanelContext(
            selectedText: nil,
            activeApp: "Terminal",
            windowTitle: nil,
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil,
            clipboardText: "Copied text"
        )
        let selectionContext = QuickPanelContext(
            selectedText: "Selected text",
            activeApp: "Terminal",
            windowTitle: nil,
            panelPosition: CGPoint(x: 0, y: 0),
            clipboardImage: nil
        )

        XCTAssertTrue(QuickPanelManager.shouldExpireClipboardTextContext(
            clipboardContext,
            inputText: "",
            isLoading: false,
            isStreaming: false
        ))
        XCTAssertFalse(QuickPanelManager.shouldExpireClipboardTextContext(
            selectionContext,
            inputText: "",
            isLoading: false,
            isStreaming: false
        ))
        XCTAssertFalse(QuickPanelManager.shouldExpireClipboardTextContext(
            clipboardContext,
            inputText: "Draft",
            isLoading: false,
            isStreaming: false
        ))
        XCTAssertFalse(QuickPanelManager.shouldExpireClipboardTextContext(
            clipboardContext,
            inputText: "",
            isLoading: true,
            isStreaming: false
        ))
        XCTAssertFalse(QuickPanelManager.shouldExpireClipboardTextContext(
            clipboardContext,
            inputText: "",
            isLoading: false,
            isStreaming: true
        ))
    }

    @MainActor
    func test_localSelectionProviderPrefersPDFSelectionOverEditorSelection() async {
        var editorSelectionWasRequested = false
        let provider = QuickPanelLocalSelectionProvider(
            pdfSelection: { " PDF selection " },
            editorSelection: {
                editorSelectionWasRequested = true
                return "Editor selection"
            }
        )

        let selectedText = await provider.selectedText()

        XCTAssertEqual(selectedText, "PDF selection")
        XCTAssertFalse(editorSelectionWasRequested)
    }

    @MainActor
    func test_localSelectionProviderFallsBackToEditorSelection() async {
        let provider = QuickPanelLocalSelectionProvider(
            pdfSelection: { nil },
            editorSelection: { " Editor selection " }
        )

        let selectedText = await provider.selectedText()

        XCTAssertEqual(selectedText, "Editor selection")
    }

    @MainActor
    func test_selectionResolverUsesLocalSelectionForTickerAndAXForOtherApps() async {
        var axSelectionWasRequested = false
        let tickerSelection = await SelectionReaderService.resolveSelectedText(
            activeBundleId: "com.example.Ticker",
            currentBundleId: "com.example.Ticker",
            localSelection: { "Local selection" },
            axSelection: {
                axSelectionWasRequested = true
                return "AX selection"
            }
        )

        XCTAssertEqual(tickerSelection, "Local selection")
        XCTAssertFalse(axSelectionWasRequested)

        var localSelectionWasRequested = false
        let externalSelection = await SelectionReaderService.resolveSelectedText(
            activeBundleId: "net.kovidgoyal.kitty",
            currentBundleId: "com.example.Ticker",
            localSelection: {
                localSelectionWasRequested = true
                return "Local selection"
            },
            axSelection: { "AX selection" }
        )

        XCTAssertEqual(externalSelection, "AX selection")
        XCTAssertFalse(localSelectionWasRequested)
    }

    func test_selectionCaptureLadderUsesClipboardWhenAXUnavailable() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: true,
            axSelection: {
                calls.append("ax")
                return .unavailable
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return .unavailable
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: "Clipboard selection", outcome: .clipboard))
        XCTAssertEqual(calls, ["ax", "hint", "hinted", "clipboard"])
    }

    func test_selectionCaptureLadderDoesNotClipboardWhenAXSaysEmpty() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: true,
            axSelection: {
                calls.append("ax")
                return .empty
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return .empty
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Cursor line copied by editor"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: nil, outcome: .emptyExternal))
        XCTAssertEqual(calls, ["ax", "hint", "hinted"])
    }

    func test_selectionCaptureLadderShortCircuitsOnAXText() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: true,
            axSelection: {
                calls.append("ax")
                return .text("AX selection")
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return .text("Hinted selection")
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: "AX selection", outcome: .ax))
        XCTAssertEqual(calls, ["ax"])
    }

    func test_selectionCaptureLadderSkipsRungsWithoutPermission() {
        var calls: [String] = []

        let result = SelectionReaderService.captureExternalSelectedText(
            hasAccessibilityPermission: false,
            axSelection: {
                calls.append("ax")
                return .text("AX selection")
            },
            hintAccessibilityTree: {
                calls.append("hint")
            },
            hintedAXSelection: {
                calls.append("hinted")
                return .text("Hinted selection")
            },
            clipboardSelection: {
                calls.append("clipboard")
                return "Clipboard selection"
            }
        )

        XCTAssertEqual(result, SelectionCaptureResult(text: nil, outcome: .noPermission))
        XCTAssertTrue(calls.isEmpty)
    }

    func test_selectionCaptureStatusMapping() {
        XCTAssertEqual(
            QuickPanelStatus.selectionCaptureStatus(for: .noPermission),
            QuickPanelStatus(
                message: "Grant Accessibility permission to capture text selections",
                tone: .warning,
                action: .openAccessibilitySettings
            )
        )
        XCTAssertEqual(
            QuickPanelStatus.selectionCaptureStatus(for: .stalePermission),
            QuickPanelStatus(
                message: "Accessibility permission is stale — remove Ticker from the list and re-add it",
                tone: .warning,
                action: .openAccessibilitySettings
            )
        )
        XCTAssertNil(QuickPanelStatus.selectionCaptureStatus(for: .emptyExternal))
        XCTAssertNil(QuickPanelStatus.selectionCaptureStatus(for: .internalApp))
        XCTAssertNil(QuickPanelStatus.selectionCaptureStatus(for: .axHinted))
    }

    func test_pasteboardSnapshotRestoresItemsAndTypes() throws {
        let pasteboardName = NSPasteboard.Name("TickerPasteboardSnapshotTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        let binaryType = NSPasteboard.PasteboardType("com.ticker.test.binary")
        let customTextType = NSPasteboard.PasteboardType("com.ticker.test.custom-text")
        let binaryData = Data([0x01, 0x02, 0x03, 0xff])

        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
        }

        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("Original string", forType: .string))
        XCTAssertTrue(firstItem.setData(binaryData, forType: binaryType))

        let secondItem = NSPasteboardItem()
        XCTAssertTrue(secondItem.setString("Custom payload", forType: customTextType))

        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Mutated", forType: .string))

        snapshot.restore(to: pasteboard)

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "Original string")
        XCTAssertEqual(restoredItems[0].data(forType: binaryType), binaryData)
        XCTAssertEqual(restoredItems[1].string(forType: customTextType), "Custom payload")
    }

    private func makeTrackedPasteboard() -> NSPasteboard {
        let pasteboardName = NSPasteboard.Name("TickerClipboardTextTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        ClipboardService.syncChangeCount(pasteboard: pasteboard)
        return pasteboard
    }

    private func writeText(
        _ text: String,
        to pasteboard: NSPasteboard,
        extraTypes: [NSPasteboard.PasteboardType] = []
    ) {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(text, forType: .string))
        for type in extraTypes {
            XCTAssertTrue(item.setString("", forType: type))
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }
}

final class QuickPanelReturnActionTests: XCTestCase {
    func test_onlyExactAIShortcutsInvokeAI() {
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: []), .save)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.capsLock]), .save)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.command]), .saveAndDevelop)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.option]), .ask)

        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.command, .shift]), .insertNewline)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.option, .shift]), .insertNewline)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.command, .option]), .insertNewline)
        XCTAssertEqual(QuickPanelReturnAction(modifierFlags: [.control]), .insertNewline)
    }
}

private actor MockRestatementProvider: RestatementProviding {
    private var responses: [String?]
    private var inputs: [String] = []

    init(responses: [String?]) {
        self.responses = responses
    }

    func restate(_ s: String) async -> String? {
        inputs.append(s)
        return responses.isEmpty ? nil : responses.removeFirst()
    }

    func inputCount() -> Int {
        inputs.count
    }
}

private actor BlockingRestatementProvider: RestatementProviding {
    private var continuation: CheckedContinuation<String?, Never>?
    private var inputs: [String] = []

    func restate(_ s: String) async -> String? {
        inputs.append(s)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func inputCount() -> Int {
        inputs.count
    }
}

private actor AutoTitleNotificationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class BridgeMessageRecorder {
    private let lock = NSLock()
    private var storedMessages: [BridgeMessage] = []

    func send(_ message: BridgeMessage) {
        lock.lock()
        storedMessages.append(message)
        lock.unlock()
    }

    func messages(ofType type: String) -> [BridgeMessage] {
        lock.lock()
        let messages = storedMessages.filter { $0.type == type }
        lock.unlock()
        return messages
    }
}

private actor SlowDocumentAIProvider {
    private var lastSystemPrompt: String?
    private var didCancel = false

    func stream(
        systemPrompt: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (SourceContext?) -> Void
    ) async {
        lastSystemPrompt = systemPrompt
        onChunk("first")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        didCancel = true
        onComplete(nil)
    }

    func prompt() -> String? {
        lastSystemPrompt
    }

    func cancelled() -> Bool {
        didCancel
    }
}

final class StreamDocumentTests: XCTestCase {
    private enum TestPDFError: Error {
        case creationFailed
    }

    private typealias RetrievalChunkFixture = (
        seq: Int,
        text: String,
        pageStart: Int,
        pageEnd: Int,
        sectionPath: String?
    )

    func test_quickPanelStreamingGenerationRejectsCancelledRequestCallbacks() {
        var gate = QuickPanelManager.StreamingGeneration()
        let requestA = gate.begin()

        gate.invalidate()
        let requestB = gate.begin()

        XCTAssertFalse(gate.owns(requestA))
        XCTAssertTrue(gate.owns(requestB))
    }

    func test_streamTitleResolutionRejectsAmbiguousAutomationTarget() throws {
        try withTempPersistenceService { service in
            let first = Stream(title: "Duplicate")
            let second = Stream(title: "Duplicate")
            let unique = Stream(title: "Unique")
            try service.saveStream(first)
            try service.saveStream(second)
            try service.saveStream(unique)

            XCTAssertEqual(try service.resolveUniqueStreamTitle("Duplicate"), .ambiguous)
            XCTAssertEqual(try service.resolveUniqueStreamTitle("Unique"), .unique(unique.id))
            XCTAssertEqual(try service.resolveUniqueStreamTitle("Missing"), .notFound)
        }
    }

    func test_ephemeralConversationDiscardsIncompleteTurnOnCancel() {
        var conversation = EphemeralConversation(
            isStreaming: true,
            currentResponse: "partial response",
            turns: [
                ConversationTurn(role: .user, content: "Earlier", contextIncluded: false),
                ConversationTurn(role: .assistant, content: "Complete", contextIncluded: false),
                ConversationTurn(role: .user, content: "Interrupted", contextIncluded: false),
            ]
        )

        conversation.discardStreamingTurn()

        XCTAssertFalse(conversation.isStreaming)
        XCTAssertEqual(conversation.currentResponse, "")
        XCTAssertEqual(conversation.turns.map(\.content), ["Earlier", "Complete"])
    }

    @MainActor
    func test_quickPanelReloadDropsDeletedStreamSelection() throws {
        try withTempPersistenceService { service in
            let first = Stream(title: "First", updatedAt: Date(timeIntervalSince1970: 1))
            let second = Stream(title: "Second", updatedAt: Date(timeIntervalSince1970: 2))
            try service.saveStream(first)
            try service.saveStream(second)
            let manager = QuickPanelManager(persistence: service)

            manager.loadAvailableStreams()
            XCTAssertEqual(manager.selectedStreamId, second.id)

            try service.deleteStream(id: second.id)
            manager.loadAvailableStreams()

            XCTAssertEqual(manager.selectedStreamId, first.id)
            XCTAssertEqual(manager.availableStreams.map(\.id), [first.id])
        }
    }

    @MainActor
    func test_quickPanelEnterAppendsAndResetsWithoutFeedbackDelay() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Inbox")
            try service.saveStream(stream)
            let manager = QuickPanelManager(persistence: service)
            manager.loadAvailableStreams()
            manager.inputText = "Captured immediately"

            await manager.handleEnter()

            let document = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(document.markdown, "Captured immediately")
            XCTAssertEqual(manager.inputText, "")
            XCTAssertFalse(manager.isLoading)
            XCTAssertFalse(manager.isVisible)
        }
    }

    @MainActor
    func test_quickPanelEscapeKeepsDraftAndRestoresInterruptedPrompt() {
        let manager = QuickPanelManager()
        manager.inputText = "Unfinished capture"

        manager.handleEscape()

        XCTAssertEqual(manager.inputText, "Unfinished capture")

        manager.inputText = ""
        manager.ephemeralConversation = EphemeralConversation(
            isStreaming: true,
            currentResponse: "Partial answer",
            turns: [ConversationTurn(role: .user, content: "Question to retry", contextIncluded: false)]
        )

        manager.handleEscape()

        XCTAssertFalse(manager.ephemeralConversation.isStreaming)
        XCTAssertEqual(manager.inputText, "Question to retry")
    }

    @MainActor
    func test_quickPanelSaveConfirmationNamesDestinationAndBackgroundWork() {
        XCTAssertEqual(
            QuickPanelManager.saveConfirmationMessage(
                destination: "PCB constraints",
                developing: false
            ),
            "Saved to PCB constraints"
        )
        XCTAssertEqual(
            QuickPanelManager.saveConfirmationMessage(
                destination: "PCB constraints",
                developing: true
            ),
            "Saved to PCB constraints · developing…"
        )
    }

    @MainActor
    func test_quickPanelIgnoresAnotherSubmitWhileSaving() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Inbox")
            try service.saveStream(stream)
            let manager = QuickPanelManager(persistence: service)
            manager.loadAvailableStreams()
            manager.inputText = "Only one copy"
            manager.isLoading = true

            await manager.handleEnter()

            XCTAssertNil(try service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(manager.inputText, "Only one copy")
        }
    }

    func test_v14MigrationCreatesPDFHighlightsTable() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        XCTAssertNotNil(service)
        service = nil

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        let tableExists = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'pdf_highlights'"
            ) != nil
        }
        let indexExists = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_pdf_highlights_source'"
            ) != nil
        }

        XCTAssertTrue(tableExists)
        XCTAssertTrue(indexExists)
    }

    func test_v15MigrationAddsOriginalPathToSources() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        XCTAssertNotNil(service)
        service = nil

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        let columnExists = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sources)")
                .contains { row in
                    let name: String = row["name"]
                    return name == "original_path"
                }
        }

        XCTAssertTrue(columnExists)
    }

    func test_v16MigrationDropsLegacyChunksAndAddsIndexStatus() throws {
        let streamId = UUID()
        let sourceId = UUID()

        try withSeededV15Database { db in
            try insertStream(db, id: streamId, title: "Legacy Chunks", createdAt: 900)
            try insertV15Source(
                db,
                id: sourceId,
                streamId: streamId,
                displayName: "Legacy.pdf",
                fileType: "pdf",
                pageCount: 2
            )
            try db.execute(
                sql: """
                    INSERT INTO source_chunks (
                        id, source_id, chunk_index, content, token_count, page_start, page_end, embedding_status, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    sourceId.uuidString,
                    4,
                    "Distinct legacy chunk text",
                    6,
                    2,
                    2,
                    "pending",
                    1_000
                ]
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let statuses = try service.loadSourceIndexStatuses(streamId: streamId)
            XCTAssertEqual(statuses[sourceId], .pending)

            let chunks = try service.loadSourceChunks(sourceId: sourceId)
            XCTAssertTrue(chunks.isEmpty)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let chunkColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(source_chunks)").map { row -> String in
                    row["name"]
                }
            }
            XCTAssertEqual(
                chunkColumns,
                ["id", "source_id", "seq", "text", "page_start", "page_end", "section_path"]
            )

            let ftsExists = try dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'source_chunks_fts'"
                ) != nil
            }
            XCTAssertTrue(ftsExists)

            let embeddingColumns: [String] = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(chunk_embeddings)").map { $0["name"] }
            }
            XCTAssertEqual(embeddingColumns, ["chunk_id", "model_id", "dims", "vector"])

            let ftsCount: Int = try dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count FROM source_chunks_fts")?["count"] ?? -1
            }
            XCTAssertEqual(ftsCount, 0)
        }
    }

    func test_sourceAIExcludedDefaultsFalseAndRoundTripsThroughPersistence() throws {
        let streamId = UUID()
        let sourceId = UUID()

        try withSeededV15Database { db in
            try insertStream(db, id: streamId, title: "Private Flag", createdAt: 900)
            try insertV15Source(
                db,
                id: sourceId,
                streamId: streamId,
                displayName: "Sensitive.pdf",
                fileType: "pdf",
                pageCount: 2
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            var source = try XCTUnwrap(service.loadSource(id: sourceId))
            XCTAssertFalse(source.aiExcluded)

            try service.setSourceAIExcluded(sourceId, excluded: true)
            source = try XCTUnwrap(service.loadSource(id: sourceId))
            XCTAssertTrue(source.aiExcluded)
            XCTAssertEqual(try service.loadStream(id: streamId)?.sources.first?.aiExcluded, true)

            source.aiExcluded = false
            try service.saveSource(source)
            XCTAssertEqual(try service.loadSource(id: sourceId)?.aiExcluded, false)
            XCTAssertEqual(try service.loadStream(id: streamId)?.sources.first?.aiExcluded, false)
        }
    }

    func test_v18MigrationAddsLivingAutoTitleColumnsToFreshDatabase() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let columns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(streams)").map { row -> String in
                    row["name"]
                }
            }

            XCTAssertTrue(columns.contains("title_locked"))
            XCTAssertTrue(columns.contains("auto_titled_at"))
            XCTAssertTrue(columns.contains("auto_titled_length"))
            XCTAssertTrue(columns.contains("source_scope"))
        }
    }

    func test_v18MigrationBackfillsExistingCustomTitlesLocked() throws {
        let customStreamId = UUID()
        let untitledStreamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: customStreamId, title: "Claimed title", createdAt: 900)
            try insertStream(db, id: untitledStreamId, title: "Untitled", createdAt: 901)
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let customState = try XCTUnwrap(service.loadAutoTitleState(streamId: customStreamId))
            let untitledState = try XCTUnwrap(service.loadAutoTitleState(streamId: untitledStreamId))

            XCTAssertTrue(customState.titleLocked)
            XCTAssertFalse(untitledState.titleLocked)
        }
    }

    func test_updateStreamTitleLocksAndUnclaimsTitle() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)

            try service.updateStreamTitle(id: stream.id, title: "Manual title")
            var state = try XCTUnwrap(service.loadAutoTitleState(streamId: stream.id))
            XCTAssertEqual(state.title, "Manual title")
            XCTAssertTrue(state.titleLocked)

            try service.updateStreamTitle(id: stream.id, title: "Untitled")
            state = try XCTUnwrap(service.loadAutoTitleState(streamId: stream.id))
            XCTAssertEqual(state.title, "Untitled")
            XCTAssertFalse(state.titleLocked)

            try service.updateStreamTitle(id: stream.id, title: "")
            state = try XCTUnwrap(service.loadAutoTitleState(streamId: stream.id))
            XCTAssertEqual(state.title, "")
            XCTAssertFalse(state.titleLocked)
        }
    }

    func test_autoTitleServiceTitlesUntitledStreamOnFirstSave() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)

            let provider = MockRestatementProvider(responses: ["Generated Title"])
            let notifications = AutoTitleNotificationCounter()
            let autoTitleService = AutoTitleService(
                persistence: service,
                restatementProvider: provider,
                now: { Date(timeIntervalSince1970: 1_000) },
                onStreamsChanged: { await notifications.increment() }
            )
            let markdown = "Short note"

            await autoTitleService.scheduleIfNeeded(streamId: stream.id, markdown: markdown)

            let updated = try XCTUnwrap(service.loadStream(id: stream.id))
            let state = try XCTUnwrap(service.loadAutoTitleState(streamId: stream.id))
            let inputCount = await provider.inputCount()
            let notificationCount = await notifications.value()
            XCTAssertEqual(updated.title, "Generated Title")
            XCTAssertEqual(state.autoTitledLength, markdown.utf16.count)
            XCTAssertEqual(inputCount, 1)
            XCTAssertEqual(notificationCount, 1)
        }
    }

    func test_autoTitleServiceSkipsUnderMinimumDelta() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)
            try service.applyAutoTitle(
                streamId: stream.id,
                title: "Prior Title",
                markdownLength: 200,
                now: Date(timeIntervalSince1970: 0)
            )

            let provider = MockRestatementProvider(responses: ["Should Not Run"])
            let autoTitleService = AutoTitleService(
                persistence: service,
                restatementProvider: provider,
                now: { Date(timeIntervalSince1970: 1_000) }
            )

            await autoTitleService.scheduleIfNeeded(
                streamId: stream.id,
                markdown: String(repeating: "a", count: 250)
            )

            let inputCount = await provider.inputCount()
            XCTAssertEqual(inputCount, 0)
            XCTAssertEqual(try service.loadStream(id: stream.id)?.title, "Prior Title")
        }
    }

    func test_autoTitleServiceSkipsRecentAutoTitle() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)
            try service.applyAutoTitle(
                streamId: stream.id,
                title: "Recent Title",
                markdownLength: 0,
                now: Date(timeIntervalSince1970: 1_000)
            )

            let provider = MockRestatementProvider(responses: ["Should Not Run"])
            let autoTitleService = AutoTitleService(
                persistence: service,
                restatementProvider: provider,
                now: { Date(timeIntervalSince1970: 1_060) }
            )

            await autoTitleService.scheduleIfNeeded(
                streamId: stream.id,
                markdown: String(repeating: "a", count: 250)
            )

            let inputCount = await provider.inputCount()
            XCTAssertEqual(inputCount, 0)
            XCTAssertEqual(try service.loadStream(id: stream.id)?.title, "Recent Title")
        }
    }

    func test_autoTitleServiceRunsWhenDeltaIsAtLeastTwoHundredUTF16Units() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)
            try service.applyAutoTitle(
                streamId: stream.id,
                title: "Prior Title",
                markdownLength: 0,
                now: Date(timeIntervalSince1970: 0)
            )

            let provider = MockRestatementProvider(responses: ["Updated Title"])
            let autoTitleService = AutoTitleService(
                persistence: service,
                restatementProvider: provider,
                now: { Date(timeIntervalSince1970: 1_000) }
            )

            await autoTitleService.scheduleIfNeeded(
                streamId: stream.id,
                markdown: String(repeating: "🙂", count: 100)
            )

            let inputCount = await provider.inputCount()
            XCTAssertEqual(inputCount, 1)
            XCTAssertEqual(try service.loadStream(id: stream.id)?.title, "Updated Title")
            XCTAssertEqual(
                try service.loadAutoTitleState(streamId: stream.id)?.autoTitledLength,
                String(repeating: "🙂", count: 100).utf16.count
            )
        }
    }

    func test_autoTitleServiceDropsDuplicateInFlightRequestForStream() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Untitled")
            try service.saveStream(stream)

            let provider = BlockingRestatementProvider()
            let autoTitleService = AutoTitleService(
                persistence: service,
                restatementProvider: provider,
                now: { Date(timeIntervalSince1970: 1_000) }
            )
            let markdown = String(repeating: "a", count: 250)
            let task = Task {
                await autoTitleService.scheduleIfNeeded(streamId: stream.id, markdown: markdown)
            }

            for _ in 0..<50 {
                if await provider.inputCount() > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var inputCount = await provider.inputCount()
            XCTAssertEqual(inputCount, 1)

            await autoTitleService.scheduleIfNeeded(streamId: stream.id, markdown: markdown + "more")
            inputCount = await provider.inputCount()
            XCTAssertEqual(inputCount, 1)

            await provider.complete("Generated Once")
            await task.value

            XCTAssertEqual(try service.loadStream(id: stream.id)?.title, "Generated Once")
        }
    }

    func test_setSourceScopePersistsAcrossReload() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scope")
            try service.saveStream(stream)

            XCTAssertTrue(try service.setSourceScope(streamId: stream.id, scope: .all))
            XCTAssertEqual(try service.loadStream(id: stream.id)?.sourceScope, .all)

            XCTAssertTrue(try service.setSourceScope(streamId: stream.id, scope: .none))
            XCTAssertEqual(try service.loadStream(id: stream.id)?.sourceScope, SourceScope.none)
        }
    }

    func test_sourceRetrievalFailureHasHonestErrorAndCompletionMode() async throws {
        XCTAssertEqual(
            OrchestratorError.sourceRetrievalFailed.localizedDescription,
            "Source retrieval failed — answer not generated"
        )

        let recorder = BridgeMessageRecorder()
        let handler = await AIMessageHandler(
            sendToWeb: { recorder.send($0) },
            routeDocumentAI: { _, _, _, _, _, _, _, _, onComplete, _, _ in
                onComplete(SourceContext(text: "", chunks: [], mode: .unavailable))
            }
        )
        let requestId = UUID().uuidString

        await handler.handle(BridgeMessage(type: "thinkDocument", payload: [
            "requestId": AnyCodable(requestId),
            "query": AnyCodable("Use my sources"),
            "sourceScope": AnyCodable("auto"),
            "imageURLs": AnyCodable([])
        ]))

        try await waitUntil {
            recorder.messages(ofType: "documentAIComplete").contains { message in
                message.payload?["sourceContextMode"]?.value as? String == "unavailable"
            }
        }
    }

    func test_orchestratorMergesCapturedAndRetrievedContextWithoutLosingCitations() {
        let captured = SourceContext(text: "captured verbatim", chunks: [], mode: .passthrough)
        let chunk = RetrievedChunk(
            id: UUID(), sourceId: UUID(), sourceName: "Manual", seq: 0,
            text: "retrieved passage", pageStart: 4, pageEnd: 4,
            sectionPath: "Storage", score: -10
        )
        let retrieved = SourceContext(text: "[1] Manual, p.4:\nretrieved passage", chunks: [chunk], mode: .retrieved)

        let merged = AIOrchestrator.mergeContexts(explicit: captured, assembled: retrieved)

        XCTAssertEqual(merged?.text, "captured verbatim\n\n---\n\n[1] Manual, p.4:\nretrieved passage")
        XCTAssertEqual(merged?.chunks.map(\.id), [chunk.id])
        XCTAssertEqual(merged?.mode, .retrieved)
    }

    func test_threadAIRequestFitsAtBoundaryDropsOnlyWholeOldTurnsAndNeverTruncates() throws {
        let old = ThreadAIConversationTurn(
            requestId: "old",
            userInput: String(repeating: "old question ", count: 80),
            responseRaw: String(repeating: "old answer ", count: 80)
        )
        let recent = ThreadAIConversationTurn(
            requestId: "recent",
            userInput: "Recent question",
            responseRaw: "Recent answer"
        )
        let withoutHistory = try AIOrchestrator.prepareThreadRequest(
            query: "What follows?",
            anchorText: "A fixed starting passage.",
            streamMarkdown: "My current Stream.",
            priorTurns: [],
            sourceContext: nil
        )
        let recentTokens = [
            LLMMessage(role: "user", content: recent.userInput),
            LLMMessage(role: "assistant", content: recent.responseRaw)
        ].reduce(0) { $0 + LLMRequest.estimateTokens($1) }
        let boundary = withoutHistory.request.estimatedTokenCount
            + (withoutHistory.request.maxTokens ?? 2048)
            + recentTokens

        let prepared = try AIOrchestrator.prepareThreadRequest(
            query: "What follows?",
            anchorText: "A fixed starting passage.",
            streamMarkdown: "My current Stream.",
            priorTurns: [old, recent],
            sourceContext: nil,
            tokenBudget: boundary
        )

        XCTAssertEqual(prepared.receipt.includedPriorRequestIds, ["recent"])
        XCTAssertEqual(prepared.receipt.totalPriorExchangeCount, 2)
        XCTAssertTrue(prepared.request.fits(withinTokenBudget: boundary))
        let truncated = prepared.request.truncated(toTokenBudget: boundary)
        XCTAssertEqual(truncated.messages.map(\.role), prepared.request.messages.map(\.role))
        XCTAssertEqual(truncated.messages.map(\.content), prepared.request.messages.map(\.content))
    }

    func test_conversationAIFramesAndSanitizesPrimaryStreamAndPinnedMaterial() throws {
        let pinnedQuote = "Pinned [link](ticker-pdf://private) verbatim."
        let prepared = try AIOrchestrator.prepareThreadRequest(
            query: "Check this",
            anchorText: "Primary block",
            streamMarkdown: "Primary block\n\nWhole [Stream](ticker-thread://private)",
            pinnedContext: [ThreadAIPinnedContext(kind: .pdfQuote, quote: pinnedQuote)],
            priorTurns: [],
            sourceContext: nil
        )
        let content = prepared.request.messages.map(\.content).joined(separator: "\n")

        XCTAssertTrue(content.contains("PRIMARY anchor block"))
        XCTAssertTrue(content.contains("<primary_anchor>\nPrimary block\n</primary_anchor>"))
        XCTAssertTrue(content.contains("<stream_document>\nPrimary block\n\nWhole Stream\n</stream_document>"))
        XCTAssertTrue(content.contains("<pinned_context kind=\"pdf_quote\">\n\(pinnedQuote)\n</pinned_context>"))
        XCTAssertEqual(content.components(separatedBy: pinnedQuote).count - 1, 1)
        let pinnedFrames = prepared.request.messages.filter { $0.content.contains("<pinned_context") }
        XCTAssertFalse(pinnedFrames.contains { $0.content.contains("Primary block") })
    }

    func test_threadAIRequestRefusesOneTokenPastProtectedBoundary() throws {
        let fitted = try AIOrchestrator.prepareThreadRequest(
            query: "Question",
            anchorText: "Starting passage",
            streamMarkdown: "Whole Stream",
            priorTurns: [],
            sourceContext: nil
        )
        let exactBudget = fitted.request.estimatedTokenCount + (fitted.request.maxTokens ?? 2048)

        XCTAssertThrowsError(try AIOrchestrator.prepareThreadRequest(
            query: "Question",
            anchorText: "Starting passage",
            streamMarkdown: "Whole Stream",
            priorTurns: [],
            sourceContext: nil,
            tokenBudget: exactBudget - 1
        )) { error in
            guard case let ThreadAIRequestError.contextTooLarge(
                _, protectedTokens, sourceTokens, tokenBudget
            ) = error else {
                return XCTFail("Expected a typed thread context refusal")
            }
            XCTAssertEqual(sourceTokens, 0)
            XCTAssertEqual(tokenBudget, exactBudget - 1)
            XCTAssertEqual(protectedTokens, fitted.request.estimatedTokenCount)
        }
    }

    func test_threadAIRequestRefusesRatherThanDroppingSelectedSourceContext() throws {
        let protected = try AIOrchestrator.prepareThreadRequest(
            query: "Question",
            anchorText: "Starting passage",
            streamMarkdown: "Whole Stream",
            priorTurns: [],
            sourceContext: nil
        )
        let protectedBudget = protected.request.estimatedTokenCount
            + (protected.request.maxTokens ?? 2048)
        let sourceContext = SourceContext(
            text: String(repeating: "source passage ", count: 200),
            chunks: [],
            mode: .passthrough,
            sourceIds: [UUID()]
        )

        XCTAssertThrowsError(try AIOrchestrator.prepareThreadRequest(
            query: "Question",
            anchorText: "Starting passage",
            streamMarkdown: "Whole Stream",
            priorTurns: [],
            sourceContext: sourceContext,
            tokenBudget: protectedBudget
        )) { error in
            guard case let ThreadAIRequestError.contextTooLarge(
                largestBlock, _, sourceTokens, tokenBudget
            ) = error else {
                return XCTFail("Expected a typed source-context refusal")
            }
            XCTAssertEqual(largestBlock, "The source context")
            XCTAssertGreaterThan(sourceTokens, 0)
            XCTAssertEqual(tokenBudget, protectedBudget)
        }
    }

    func test_internalURLSanitizerKeepsLabelsAndRemovesEveryTickerScheme() {
        XCTAssertEqual(
            TickerInternalURLSanitizer.sanitize(
                "[Thread](ticker-thread://secret) [PDF](ticker-pdf://source?page=2) "
                    + "![Image](ticker-asset://stream/file.png) ticker://open/item"
            ),
            "Thread PDF Image Ticker link"
        )
    }

    func test_threadAIReplayRemovesRequestScopedCitationNumbers() throws {
        let prepared = try AIOrchestrator.prepareThreadRequest(
            query: "Follow up",
            anchorText: "Starting passage",
            streamMarkdown: "Whole Stream",
            priorTurns: [ThreadAIConversationTurn(
                requestId: "earlier",
                userInput: "How many controllers?",
                responseRaw: #"There are two. 【3|"two CAN-FD controllers"】"#
            )],
            sourceContext: nil
        )

        let replayed = prepared.request.messages
            .first { $0.role == "assistant" && $0.content.contains("There are two") }
        XCTAssertEqual(replayed?.content.trimmingCharacters(in: .whitespaces), "There are two.")
        XCTAssertFalse(replayed?.content.contains("【3") == true)
    }

    func test_orchestratorPreservesCapturedContextWhenRetrievalIsAbsentOrUnavailable() {
        let captured = SourceContext(text: "captured verbatim", chunks: [], mode: .passthrough)
        let unavailable = SourceContext(text: "", chunks: [], mode: .unavailable)

        XCTAssertEqual(AIOrchestrator.mergeContexts(explicit: captured, assembled: nil)?.text, captured.text)
        XCTAssertEqual(
            AIOrchestrator.mergeContexts(explicit: captured, assembled: unavailable)?.mode,
            .passthrough
        )
    }

    func test_orchestratorLeavesAssembledOrEmptyContextUnchanged() {
        let assembled = SourceContext(text: "source text", chunks: [], mode: .passthrough)

        XCTAssertEqual(AIOrchestrator.mergeContexts(explicit: nil, assembled: assembled)?.text, assembled.text)
        XCTAssertNil(AIOrchestrator.mergeContexts(explicit: nil, assembled: nil))
    }

    func test_documentAIContextCleaningOnlyRemovesUnderlineStorageTags() {
        XCTAssertEqual(
            AIMessageHandler.cleanedDocumentContext(
                #"<u>underlined</u> while x < y and Array<T> stays; <custom> is literal &amp; visible"#
            ),
            #"underlined while x < y and Array<T> stays; <custom> is literal &amp; visible"#
        )
        XCTAssertNil(AIMessageHandler.cleanedDocumentContext("<u></u>"))
    }

    @MainActor
    func test_documentAICancelStopsSlowStreamingProvider() async throws {
        let recorder = BridgeMessageRecorder()
        let provider = SlowDocumentAIProvider()
        let handler = AIMessageHandler(
            sendToWeb: { recorder.send($0) },
            routeDocumentAI: { _, _, _, _, _, _, systemPrompt, onChunk, onComplete, _, _ in
                await provider.stream(
                    systemPrompt: systemPrompt,
                    onChunk: onChunk,
                    onComplete: onComplete
                )
            }
        )
        let requestId = UUID().uuidString

        await handler.handle(BridgeMessage(type: "thinkDocument", payload: [
            "requestId": AnyCodable(requestId),
            "streamId": AnyCodable(UUID().uuidString),
            "query": AnyCodable("What is weak here?"),
            "imageURLs": AnyCodable([]),
            "verb": AnyCodable("challenge")
        ]))

        try await waitUntil {
            recorder.messages(ofType: "documentAIChunk").contains { message in
                message.payload?["requestId"]?.value as? String == requestId
            }
        }

        await handler.handle(BridgeMessage(type: "cancelDocumentAI", payload: [
            "requestId": AnyCodable(requestId)
        ]))

        try await waitUntil {
            recorder.messages(ofType: "documentAIError").contains { message in
                message.payload?["requestId"]?.value as? String == requestId
                    && message.payload?["errorCode"]?.value as? String == "cancelled"
            }
        }
        try await waitUntil {
            await provider.cancelled()
        }

        let prompt = await provider.prompt()
        XCTAssertEqual(prompt, Prompts.verbChallenge)
        XCTAssertTrue(recorder.messages(ofType: "documentAIComplete").isEmpty)
    }

    @MainActor
    func test_cancelAIOperationRoutesToSharedRegistry() async {
        let registry = AIOperationRegistry()
        let requestId = registry.begin(streamId: UUID(), verb: "develop", origin: "quickPanel")
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        registry.attach(task, to: requestId)
        let handler = AIMessageHandler(
            aiOperations: registry,
            sendToWeb: { _ in },
            routeDocumentAI: { _, _, _, _, _, _, _, _, _, _, _ in }
        )

        await handler.handle(BridgeMessage(type: "cancelAIOperation", payload: [
            "requestId": AnyCodable(requestId)
        ]))

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(registry.operations[requestId]?.state, .canceled)
    }

    @MainActor
    func test_documentAICompletionSavesExchangeReceipt() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Exchange Receipt")
            try service.saveStream(stream)
            let recorder = BridgeMessageRecorder()
            let requestId = "request-doc-ai"
            let chunkId = UUID()
            let sourceId = UUID()
            var routedQuery: String?
            let handler = AIMessageHandler(
                persistence: service,
                sendToWeb: { recorder.send($0) },
                routeDocumentAI: { query, _, _, _, _, _, _, onChunk, onComplete, _, onModelSelected in
                    routedQuery = query
                    onModelSelected?("provider/model")
                    onChunk("Raw [1]")
                    onComplete(SourceContext(
                        text: "Source context",
                        chunks: [
                            RetrievedChunk(
                                id: chunkId,
                                sourceId: sourceId,
                                sourceName: "Source PDF",
                                seq: 0,
                                text: "quoted source",
                                pageStart: 4,
                                pageEnd: 4,
                                sectionPath: nil,
                                score: -10
                            )
                        ],
                        mode: .retrieved
                    ))
                }
            )

            await handler.handle(BridgeMessage(type: "thinkDocument", payload: [
                "requestId": AnyCodable(requestId),
                "streamId": AnyCodable(stream.id.uuidString),
                "query": AnyCodable("Explain this"),
                "context": AnyCodable(" Selected [text](ticker-thread://private-thread) "),
                "imageURLs": AnyCodable([]),
                "verb": AnyCodable("ask")
            ]))

            try await waitUntil {
                (try? service.loadExchange(requestId: requestId)) != nil
            }

            let exchange = try XCTUnwrap(try service.loadExchange(requestId: requestId))
            XCTAssertEqual(exchange.streamId, stream.id)
            XCTAssertEqual(exchange.verb, "ask")
            XCTAssertEqual(
                exchange.userInput,
                "Selection:\nSelected [text](ticker-thread://private-thread)\n\nPrompt:\nExplain this"
            )
            XCTAssertEqual(
                routedQuery,
                "Regarding this context:\n\"\"\"\nSelected text\n\"\"\"\n\nExplain this"
            )
            XCTAssertEqual(exchange.responseRaw, "Raw [1]")
            XCTAssertEqual(exchange.model, "provider/model")

            let manifestData = try XCTUnwrap(exchange.sourceManifest.data(using: .utf8))
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [[String: Any]])
            XCTAssertEqual(manifest.count, 1)
            XCTAssertEqual(manifest[0]["chunkId"] as? String, chunkId.uuidString)
            XCTAssertEqual(manifest[0]["sourceId"] as? String, sourceId.uuidString)
            XCTAssertEqual(manifest[0]["shortTitle"] as? String, "Source PDF")
            XCTAssertFalse(recorder.messages(ofType: "documentAIComplete").isEmpty)
        }
    }

    @MainActor
    func test_conversationAISendsFullContextAndPersistsVersion2ReceiptWithoutChangingStream() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Thread AI")
            try service.saveStream(stream)
            _ = try service.saveStreamDocument(streamId: stream.id, markdown: "Stream stays unchanged.")
            let beforeDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let sentSource = SourceReference(
                streamId: stream.id,
                displayName: "Sent.txt",
                fileType: .text,
                bookmarkData: Data("sent".utf8),
                status: .ready,
                extractedText: "Sent source text"
            )
            let otherSource = SourceReference(
                streamId: stream.id,
                displayName: "Not Sent.txt",
                fileType: .text,
                bookmarkData: Data("other".utf8),
                status: .ready,
                extractedText: "Other source text"
            )
            try service.saveSource(sentSource)
            try service.saveSource(otherSource)
            let canonicalWorkingText = """
            > Read [the source](ticker-pdf://private-source?page=2).

            > A second constraint.

            Check [saved link](ticker-thread://private-note).
            """
            let thread = StreamThread(
                streamId: stream.id,
                title: "Power",
                workingText: canonicalWorkingText,
                docJSON: #"{"type":"doc","content":[]}"#,
                docFormatVersion: 1,
                anchorText: "Read [the source](ticker-pdf://private-source?page=2).",
                anchorStart: 1,
                anchorEnd: 58
            )
            try service.createStreamThread(thread, anchors: [
                StreamThreadAnchor(
                    anchorId: "anchor-1",
                    threadId: thread.threadId,
                    kind: .streamQuote,
                    quote: thread.anchorText
                ),
                StreamThreadAnchor(
                    anchorId: "anchor-2",
                    threadId: thread.threadId,
                    kind: .streamQuote,
                    quote: "A second constraint."
                ),
                StreamThreadAnchor(
                    anchorId: "anchor-range-duplicate",
                    threadId: thread.threadId,
                    kind: .streamQuote,
                    quote: "Same primary range",
                    anchorSpanId: "pm:1:58"
                ),
                StreamThreadAnchor(
                    anchorId: "anchor-whitespace",
                    threadId: thread.threadId,
                    kind: .streamQuote,
                    quote: " \n "
                )
            ])
            let prior = AIExchange(
                requestId: "prior-request",
                streamId: stream.id,
                threadId: thread.threadId,
                verb: "thread",
                userInput: "Earlier question",
                responseRaw: "Earlier answer"
            )
            try service.saveExchange(prior)

            let recorder = BridgeMessageRecorder()
            let requestId = "thread-request"
            var routedQuery: String?
            var routedRetrievalQuery: String?
            let handler = AIMessageHandler(
                persistence: service,
                sendToWeb: { recorder.send($0) },
                routeDocumentAI: { _, _, _, _, _, _, _, _, _, _, _ in },
                routeThreadAI: { query, retrievalQuery, _, _, anchorText, streamMarkdown, pinned, turns, onPrepared, onChunk, onComplete, _, onModelSelected in
                    routedQuery = query
                    routedRetrievalQuery = retrievalQuery
                    XCTAssertEqual(anchorText, thread.anchorText)
                    XCTAssertEqual(streamMarkdown, "Stream stays unchanged.")
                    XCTAssertEqual(pinned.map(\.quote), ["A second constraint."])
                    XCTAssertEqual(turns.map(\.requestId), [prior.requestId])
                    let receipt = ThreadAIRequestReceipt(
                        sourceContext: SourceContext(
                            text: sentSource.extractedText ?? "",
                            chunks: [],
                            mode: .passthrough,
                            sourceIds: [sentSource.id]
                        ),
                        includedPriorRequestIds: [prior.requestId],
                        totalPriorExchangeCount: 1
                    )
                    onPrepared(receipt)
                    onModelSelected?("provider/model")
                    onChunk("A grounded reply.")
                    onComplete(receipt)
                }
            )
            let rawPrompt = "Use [this thread](ticker-thread://private-prompt)."

            await handler.handle(BridgeMessage(type: "thinkDocument", payload: [
                "requestId": AnyCodable(requestId),
                "streamId": AnyCodable(stream.id.uuidString),
                "threadId": AnyCodable(thread.threadId.uuidString),
                "query": AnyCodable(rawPrompt),
                "sourceScope": AnyCodable("auto"),
                "imageURLs": AnyCodable([])
            ]))

            try await waitUntil { (try? service.loadExchange(requestId: requestId)) != nil }
            XCTAssertEqual(routedQuery, "Use this thread.")
            XCTAssertFalse(routedRetrievalQuery?.contains("ticker-") == true)

            let exchange = try XCTUnwrap(try service.loadExchange(requestId: requestId))
            XCTAssertEqual(exchange.threadId, thread.threadId)
            XCTAssertEqual(exchange.userInput, rawPrompt)
            XCTAssertEqual(exchange.responseRaw, "A grounded reply.")
            XCTAssertEqual(exchange.model, "provider/model")

            let data = try XCTUnwrap(exchange.sourceManifest.data(using: .utf8))
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(receipt["version"] as? Int, 2)
            XCTAssertEqual(receipt["kind"] as? String, "threadAI")
            let anchor = try XCTUnwrap(receipt["anchor"] as? [String: Any])
            XCTAssertEqual(anchor["text"] as? String, "Read the source.")
            XCTAssertEqual(anchor["kind"] as? String, "stream")
            XCTAssertEqual(anchor["from"] as? Int, 1)
            XCTAssertEqual(anchor["to"] as? Int, 58)
            let note = try XCTUnwrap(receipt["note"] as? [String: Any])
            XCTAssertEqual(note["sent"] as? Bool, false)
            let turns = try XCTUnwrap(receipt["turns"] as? [String: Any])
            XCTAssertEqual(turns["includedRequestIds"] as? [String], [prior.requestId])
            XCTAssertEqual(turns["totalAtSend"] as? Int, 1)
            let pinned = try XCTUnwrap(receipt["pinned"] as? [[String: Any]])
            XCTAssertEqual(pinned.map { $0["quote"] as? String }, ["A second constraint."])
            let streamDocument = try XCTUnwrap(receipt["streamDocument"] as? [String: Any])
            XCTAssertEqual(streamDocument["sent"] as? Bool, true)
            XCTAssertEqual(streamDocument["charCount"] as? Int, "Stream stays unchanged.".count)
            let sources = try XCTUnwrap(receipt["sources"] as? [[String: Any]])
            XCTAssertEqual(sources.map { $0["sourceId"] as? String }, [sentSource.id.uuidString])
            XCTAssertFalse(sources.contains { $0["sourceId"] as? String == otherSource.id.uuidString })

            let afterDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(afterDocument.markdown, beforeDocument.markdown)
            XCTAssertEqual(afterDocument.revision, beforeDocument.revision)
            XCTAssertEqual(recorder.messages(ofType: "threadAIContext").count, 1)
            XCTAssertEqual(recorder.messages(ofType: "documentAIComplete").count, 1)
        }
    }

    @MainActor
    func test_threadAIContextRefusalHasTypedWireOutcomeAndSavesNothing() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Thread refusal")
            try service.saveStream(stream)
            let thread = StreamThread(streamId: stream.id, anchorText: "Large passage")
            try service.createStreamThread(thread)
            let recorder = BridgeMessageRecorder()
            let requestId = "refused-thread-request"
            let handler = AIMessageHandler(
                persistence: service,
                sendToWeb: { recorder.send($0) },
                routeDocumentAI: { _, _, _, _, _, _, _, _, _, _, _ in },
                routeThreadAI: { _, _, _, _, _, _, _, _, _, _, _, onError, _ in
                    onError(ThreadAIRequestError.contextTooLarge(
                        largestBlock: "Your note",
                        protectedTokens: 98_000,
                        sourceTokens: 4_000,
                        tokenBudget: 100_000
                    ))
                }
            )

            await handler.handle(BridgeMessage(type: "thinkDocument", payload: [
                "requestId": AnyCodable(requestId),
                "streamId": AnyCodable(stream.id.uuidString),
                "threadId": AnyCodable(thread.threadId.uuidString),
                "query": AnyCodable("Question"),
                "imageURLs": AnyCodable([])
            ]))

            try await waitUntil {
                recorder.messages(ofType: "documentAIError").contains {
                    $0.payload?["requestId"]?.value as? String == requestId
                }
            }
            let error = try XCTUnwrap(recorder.messages(ofType: "documentAIError").last)
            XCTAssertEqual(error.payload?["errorCode"]?.value as? String, "thread_context_too_large")
            XCTAssertEqual(error.payload?["largestBlock"]?.value as? String, "Your note")
            XCTAssertEqual(error.payload?["protectedTokens"]?.intValue, 98_000)
            XCTAssertEqual(error.payload?["sourceTokens"]?.intValue, 4_000)
            XCTAssertEqual(error.payload?["tokenBudget"]?.intValue, 100_000)
            XCTAssertNil(try service.loadExchange(requestId: requestId))
        }
    }

    func test_v19MigrationAddsScrollRestoreColumnsToFreshDatabase() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let documentColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(stream_documents)").map { row -> String in
                    row["name"]
                }
            }
            let sourceColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(sources)").map { row -> String in
                    row["name"]
                }
            }

            XCTAssertTrue(documentColumns.contains("scroll_offset"))
            XCTAssertTrue(sourceColumns.contains("last_page_index"))
        }
    }

    func test_v20MigrationAddsProvenanceTablesToFreshDatabase() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let tables = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                ).map { row -> String in row["name"] }
            }
            let indexes = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ).map { row -> String in row["name"] }
            }
            let spanColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(provenance_spans)").map { row -> String in
                    row["name"]
                }
            }
            let exchangeColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(ai_exchanges)").map { row -> String in
                    row["name"]
                }
            }

            XCTAssertTrue(tables.contains("provenance_spans"))
            XCTAssertTrue(tables.contains("ai_exchanges"))
            XCTAssertTrue(indexes.contains("idx_prov_stream"))
            XCTAssertEqual(
                spanColumns,
                ["span_id", "stream_id", "start", "end", "origin", "request_id", "source_id", "meta", "text_hash", "created_at"]
            )
            XCTAssertEqual(
                exchangeColumns,
                [
                    "request_id", "stream_id", "verb", "user_input", "source_manifest",
                    "response_raw", "model", "created_at", "thread_id", "thread_disposition"
                ]
            )
        }
    }

    func test_v30MigrationCreatesConversationAnchorColumns() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let columns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(stream_threads)").map { row -> String in
                    row["name"]
                }
            }
            let anchorColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(stream_thread_anchors)").map { row -> String in
                    row["name"]
                }
            }
            let indexes = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ).map { row -> String in row["name"] }
            }
            let threadForeignKey = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(ai_exchanges)")
                    .first { (row: Row) -> Bool in row["from"] as String == "thread_id" }
            }

            XCTAssertEqual(
                columns,
                [
                    "thread_id", "stream_id", "title", "working_text", "anchor_text",
                    "anchor_span_id", "source_id", "highlight_id", "revision", "created_at", "updated_at",
                    "doc_json", "doc_format_version", "anchor_start", "anchor_end", "detached", "ephemeral"
                ]
            )
            XCTAssertEqual(
                anchorColumns,
                [
                    "anchor_id", "thread_id", "kind", "quote", "anchor_span_id",
                    "source_id", "highlight_id", "created_at"
                ]
            )
            XCTAssertTrue(indexes.contains("idx_stream_threads_stream_updated"))
            XCTAssertTrue(indexes.contains("idx_ai_exchanges_thread"))
            XCTAssertTrue(indexes.contains("idx_stream_thread_anchors_thread"))
            XCTAssertTrue(indexes.contains("idx_stream_thread_anchors_span"))
            XCTAssertEqual(threadForeignKey?["table"] as String?, "stream_threads")
            XCTAssertEqual(threadForeignKey?["on_delete"] as String?, "SET NULL")
        }
    }

    func test_v30MigrationDetachesPrototypeThreadRows() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        var service: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        let stream = Stream(title: "Prototype migration")
        try service?.saveStream(stream)
        let thread = StreamThread(streamId: stream.id, anchorText: "Prototype anchor")
        try service?.createStreamThread(thread)
        service = nil

        var fixtureDB: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try fixtureDB?.write { db in
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN ephemeral")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN detached")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN anchor_end")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN anchor_start")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v30_conversation_anchors'")
        }
        fixtureDB = nil

        service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        let migrated = try XCTUnwrap(service?.loadConversationAnchors(streamId: stream.id).first)
        XCTAssertEqual(migrated.threadId, thread.threadId)
        XCTAssertNil(migrated.anchorStart)
        XCTAssertNil(migrated.anchorEnd)
        XCTAssertTrue(migrated.detached)
        XCTAssertFalse(migrated.ephemeral)
    }

    func test_conversationAnchorProseMirrorPositionsRoundTripWithDocumentAndSkipMissingThread() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Anchor save")
            try service.saveStream(stream)
            let initial = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let thread = StreamThread(
                streamId: stream.id,
                anchorText: "🙂",
                anchorStart: 1,
                anchorEnd: 3,
                ephemeral: true
            )
            try service.createStreamThread(thread)
            // These are ProseMirror positions; Swift must only round-trip them.
            let update = ConversationAnchorUpdate(
                threadId: thread.threadId,
                anchorStart: 2,
                anchorEnd: 4,
                detached: false
            )
            let missing = ConversationAnchorUpdate(
                threadId: UUID(),
                anchorStart: 8,
                anchorEnd: 13,
                detached: false
            )
            let docJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"a🙂b"}]}]}"#

            let revision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: docJSON,
                docFormatVersion: 1,
                markdown: "a🙂b",
                baseRevision: initial.revision,
                spans: [],
                conversationAnchors: [missing, update]
            )

            let anchors = try service.loadConversationAnchors(streamId: stream.id)
            let loaded = try XCTUnwrap(anchors.first)
            XCTAssertEqual(anchors.count, 1)
            XCTAssertEqual(loaded.anchorStart, 2)
            XCTAssertEqual(loaded.anchorEnd, 4)
            XCTAssertFalse(loaded.detached)
            XCTAssertTrue(loaded.ephemeral)
            let document = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(document.docJSON, docJSON)
            XCTAssertEqual(document.markdown, "a🙂b")
            XCTAssertEqual(document.revision, revision)

            XCTAssertThrowsError(try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: docJSON,
                docFormatVersion: 1,
                markdown: "stale",
                baseRevision: initial.revision,
                spans: [],
                conversationAnchors: [ConversationAnchorUpdate(
                    threadId: thread.threadId,
                    anchorStart: 0,
                    anchorEnd: 0,
                    detached: true
                )]
            )) { error in
                let conflict = error as? StreamDocumentRevisionConflict
                XCTAssertEqual(conflict?.revision, revision)
                XCTAssertEqual(conflict?.conversationAnchors.first?.anchorStart, 2)
            }
            XCTAssertEqual(try service.loadConversationAnchors(streamId: stream.id).first?.anchorStart, 2)
        }
    }

    func test_streamThreadsRoundTripInUpdatedOrderAndRejectStaleSave() throws {
        try withTempPersistenceService { service in
            let stream = Stream(
                title: "Threads",
                createdAt: Date(timeIntervalSince1970: 500),
                updatedAt: Date(timeIntervalSince1970: 1_500)
            )
            let otherStream = Stream(title: "Other")
            try service.saveStream(stream)
            try service.saveStream(otherStream)
            let first = StreamThread(
                streamId: stream.id,
                title: "First",
                anchorText: "An earlier passage",
                anchorSpanId: "thread-anchor-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
            let second = StreamThread(
                streamId: stream.id,
                title: "Second",
                anchorText: "A later passage",
                anchorSpanId: "thread-anchor-2",
                createdAt: Date(timeIntervalSince1970: 2_000),
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )

            try service.createStreamThread(first)
            XCTAssertEqual(
                try service.loadStream(id: stream.id)?.updatedAt,
                stream.updatedAt,
                "An imported thread timestamp must not move a Stream backwards"
            )
            try service.createStreamThread(second)
            XCTAssertEqual(
                try service.loadStream(id: stream.id)?.updatedAt,
                second.updatedAt,
                "Thread work is deliberate Stream activity"
            )
            XCTAssertEqual(try service.loadStreamThreads(streamId: stream.id), [second, first])
            XCTAssertEqual(
                try service.loadStreamThread(threadId: first.threadId, streamId: stream.id),
                first
            )

            let saved = try service.saveStreamThread(
                threadId: first.threadId,
                streamId: stream.id,
                title: "Power budget",
                baseRevision: 0
            )
            XCTAssertEqual(saved.revision, 1)
            XCTAssertEqual(saved.title, "Power budget")
            XCTAssertEqual(saved.workingText, first.workingText)
            XCTAssertEqual(try service.loadStreamThreads(streamId: stream.id).first?.threadId, first.threadId)

            XCTAssertThrowsError(try service.saveStreamThread(
                threadId: first.threadId,
                streamId: stream.id,
                title: "Stale",
                baseRevision: 0
            )) { error in
                let conflict = error as? StreamThreadRevisionConflict
                XCTAssertEqual(conflict?.current, saved)
            }
            XCTAssertEqual(
                try service.loadStreamThread(threadId: first.threadId, streamId: stream.id),
                saved
            )

            XCTAssertThrowsError(try service.saveStreamThread(
                threadId: first.threadId,
                streamId: otherStream.id,
                title: "Foreign",
                baseRevision: saved.revision
            )) { error in
                XCTAssertEqual(error as? StreamThreadPersistenceError, .threadNotFound)
            }
            XCTAssertThrowsError(try service.loadThreadExchanges(
                threadId: first.threadId,
                streamId: otherStream.id
            )) { error in
                XCTAssertEqual(error as? StreamThreadPersistenceError, .threadNotFound)
            }
            XCTAssertThrowsError(try service.saveExchange(AIExchange(
                requestId: "foreign-thread",
                streamId: otherStream.id,
                threadId: first.threadId,
                verb: "ask",
                userInput: "Must not attach.",
                responseRaw: "No"
            ))) { error in
                XCTAssertEqual(error as? StreamThreadPersistenceError, .threadNotFound)
            }
            XCTAssertNil(try service.loadExchange(requestId: "foreign-thread"))
        }
    }

    func test_conversationAnchorsAndPendingAnswerRoundTripAndDeleteTogether() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Power research")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Power Guide.pdf",
                fileType: .pdf,
                bookmarkData: Data("power".utf8),
                status: .ready
            )
            try service.saveSource(source)

            let threadId = UUID()
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 7,
                rects: [PDFHighlightRect(page: 7, x: 1, y: 2, w: 3, h: 4)],
                quote: "Sleep current is 12 uA.",
                createdAt: Date(timeIntervalSince1970: 7_000)
            )
            let streamAnchor = StreamThreadAnchor(
                anchorId: "stream-anchor",
                threadId: threadId,
                kind: .streamQuote,
                quote: "The battery must last six months.",
                anchorSpanId: "stream-span",
                createdAt: Date(timeIntervalSince1970: 7_001)
            )
            let pdfAnchor = StreamThreadAnchor(
                anchorId: "pdf-anchor",
                threadId: threadId,
                kind: .pdfQuote,
                quote: highlight.quote,
                sourceId: source.id,
                highlightId: highlight.id,
                createdAt: Date(timeIntervalSince1970: 7_002)
            )
            let docJSON = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            let thread = StreamThread(
                threadId: threadId,
                streamId: stream.id,
                title: "Battery life",
                workingText: "Battery life",
                docJSON: docJSON,
                docFormatVersion: 1,
                anchorText: streamAnchor.quote ?? "",
                anchorSpanId: streamAnchor.anchorSpanId
            )

            try service.createStreamThread(
                thread,
                anchors: [streamAnchor, pdfAnchor],
                pdfHighlights: [highlight]
            )
            XCTAssertEqual(
                try service.loadStreamThreadAnchors(threadId: threadId, streamId: stream.id),
                [streamAnchor, pdfAnchor]
            )
            XCTAssertEqual(
                try service.loadStreamThread(threadId: threadId, streamId: stream.id)?.docJSON,
                docJSON
            )

            let exchange = AIExchange(
                requestId: "conversation-answer",
                streamId: stream.id,
                threadId: threadId,
                verb: "ask",
                userInput: "Can this meet the target?",
                responseRaw: "Only in the lowest-power mode.",
                threadDisposition: "pending"
            )
            try service.saveExchange(exchange)
            try service.setThreadExchangeDisposition(
                requestId: exchange.requestId,
                threadId: threadId,
                streamId: stream.id,
                disposition: "kept"
            )
            XCTAssertEqual(try service.loadExchange(requestId: exchange.requestId)?.threadDisposition, "kept")

            let saved = try service.saveStreamThread(
                threadId: threadId,
                streamId: stream.id,
                title: "Decision",
                baseRevision: 0
            )
            XCTAssertEqual(saved.title, "Decision")
            XCTAssertEqual(saved.workingText, thread.workingText)
            XCTAssertEqual(saved.docJSON, docJSON)
            XCTAssertEqual(saved.docFormatVersion, thread.docFormatVersion)

            XCTAssertEqual(try service.deleteStreamThread(threadId: threadId, streamId: stream.id), [highlight.id])
            XCTAssertNil(try service.loadStreamThread(threadId: threadId, streamId: stream.id))
            XCTAssertNil(try service.loadExchange(requestId: exchange.requestId))
            XCTAssertTrue(try service.loadPDFHighlights(sourceId: source.id).isEmpty)
        }
    }

    func test_streamThreadRejectsSourceAndHighlightOutsideItsStream() throws {
        try withTempPersistenceService { service in
            let firstStream = Stream(title: "First")
            let secondStream = Stream(title: "Second")
            try service.saveStream(firstStream)
            try service.saveStream(secondStream)
            let firstSource = SourceReference(
                streamId: firstStream.id,
                displayName: "First.pdf",
                fileType: .pdf,
                bookmarkData: Data("first".utf8),
                status: .ready
            )
            let secondSource = SourceReference(
                streamId: secondStream.id,
                displayName: "Second.pdf",
                fileType: .pdf,
                bookmarkData: Data("second".utf8),
                status: .ready
            )
            try service.saveSource(firstSource)
            try service.saveSource(secondSource)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: firstSource.id,
                page: 3,
                rects: [PDFHighlightRect(page: 3, x: 1, y: 2, w: 3, h: 4)],
                quote: "Power requirements",
                createdAt: Date(timeIntervalSince1970: 3_000)
            )
            try service.savePDFHighlight(highlight)

            XCTAssertThrowsError(try service.createStreamThread(StreamThread(
                streamId: secondStream.id,
                anchorText: highlight.quote,
                sourceId: firstSource.id,
                highlightId: highlight.id
            ))) { error in
                XCTAssertEqual(error as? StreamThreadPersistenceError, .sourceOutsideStream)
            }
            XCTAssertThrowsError(try service.createStreamThread(StreamThread(
                streamId: secondStream.id,
                anchorText: highlight.quote,
                sourceId: secondSource.id,
                highlightId: highlight.id
            ))) { error in
                XCTAssertEqual(error as? StreamThreadPersistenceError, .highlightOutsideSource)
            }
        }
    }

    func test_threadExchangesSurviveOrphanCleanupAndCascadeWithTheirStream() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Thread exchange")
            try service.saveStream(stream)
            let thread = StreamThread(streamId: stream.id, anchorText: "A claim")
            try service.createStreamThread(thread)
            let exchange = AIExchange(
                requestId: "thread-request",
                streamId: stream.id,
                threadId: thread.threadId,
                verb: "ask",
                userInput: "What supports this?",
                responseRaw: "The source does.",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            try service.saveExchange(exchange)

            try service.deleteOrphanExchanges(streamId: stream.id)
            XCTAssertEqual(try service.loadExchange(requestId: exchange.requestId), exchange)
            XCTAssertEqual(
                try service.loadThreadExchanges(threadId: thread.threadId, streamId: stream.id),
                [exchange]
            )

            try service.deleteStream(id: stream.id)
            XCTAssertTrue(try service.loadStreamThreads(streamId: stream.id).isEmpty)
            XCTAssertNil(try service.loadExchange(requestId: exchange.requestId))
        }
    }

    func test_deletingSourceClearsThreadSourceAndHighlight() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Source deletion")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Part.pdf",
                fileType: .pdf,
                bookmarkData: Data("part".utf8),
                status: .ready
            )
            try service.saveSource(source)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "A source passage",
                createdAt: Date(timeIntervalSince1970: 4_000)
            )
            try service.savePDFHighlight(highlight)
            let thread = StreamThread(
                streamId: stream.id,
                anchorText: highlight.quote,
                sourceId: source.id,
                highlightId: highlight.id
            )
            let anchor = StreamThreadAnchor(
                threadId: thread.threadId,
                kind: .pdfQuote,
                quote: highlight.quote,
                sourceId: source.id,
                highlightId: highlight.id
            )
            try service.createStreamThread(thread, anchors: [anchor])

            try service.deleteSource(id: source.id)

            let loaded = try XCTUnwrap(service.loadStreamThread(
                threadId: thread.threadId,
                streamId: stream.id
            ))
            XCTAssertNil(loaded.sourceId)
            XCTAssertNil(loaded.highlightId)
            XCTAssertEqual(loaded.anchorText, highlight.quote)
            let staleAnchor = try XCTUnwrap(
                service.loadStreamThreadAnchors(threadId: thread.threadId, streamId: stream.id).first
            )
            XCTAssertEqual(staleAnchor.quote, highlight.quote)
            XCTAssertNil(staleAnchor.sourceId)
            XCTAssertNil(staleAnchor.highlightId)
        }
    }

    func test_deletingThreadRowKeepsExchangeAndClearsItsThreadId() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Deleted thread")
            try service.saveStream(stream)
            let thread = StreamThread(streamId: stream.id, anchorText: "Claim")
            try service.createStreamThread(thread)
            let exchange = AIExchange(
                requestId: "kept-exchange",
                streamId: stream.id,
                threadId: thread.threadId,
                verb: "ask",
                userInput: "Question",
                responseRaw: "Answer",
                createdAt: Date(timeIntervalSince1970: 5_000)
            )
            try service.saveExchange(exchange)

            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM stream_threads WHERE thread_id = ?",
                    arguments: [thread.threadId.uuidString]
                )
            }

            let kept = try XCTUnwrap(service.loadExchange(requestId: exchange.requestId))
            XCTAssertNil(kept.threadId)
            XCTAssertEqual(kept.responseRaw, exchange.responseRaw)
        }
    }

    @MainActor
    func test_threadBridgeCreatesLoadsAndSavesConversations() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Bridge conversations")
            let otherStream = Stream(title: "Other bridge stream")
            try service.saveStream(stream)
            try service.saveStream(otherStream)
            let docJSON = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            let thread = StreamThread(
                streamId: stream.id,
                title: "Original",
                workingText: "Frozen draft",
                docJSON: docJSON,
                docFormatVersion: 1,
                anchorStart: 2,
                anchorEnd: 6,
                ephemeral: true
            )
            try service.createStreamThread(thread)

            let recorder = BridgeMessageRecorder()
            let handler = ThreadMessageHandler(
                persistence: service,
                sendToWeb: recorder.send,
                sendBridgeError: { originalType, reason in
                    recorder.send(BridgeMessage(type: "bridgeError", payload: [
                        "originalType": AnyCodable(originalType),
                        "reason": AnyCodable(reason)
                    ]))
                }
            )
            XCTAssertEqual(handler.handledTypes, [
                "addStreamThreadAnchor",
                "listConversations",
                "createStreamThread",
                "deleteStreamThread",
                "loadStreamThread",
                "removeStreamThreadAnchor",
                "saveStreamThread"
            ])

            await handler.handle(BridgeMessage(
                type: "listConversations",
                payload: ["streamId": AnyCodable(stream.id.uuidString)],
                callbackId: "list"
            ))
            let listResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "list" }
            )
            let conversations = try XCTUnwrap(
                listResponse.payload?["conversations"]?.value as? [[String: Any]]
            )
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(conversations[0]["threadId"] as? String, thread.threadId.uuidString)
            XCTAssertEqual(conversations[0]["anchorStart"] as? Int, 2)
            XCTAssertEqual(conversations[0]["anchorEnd"] as? Int, 6)
            XCTAssertEqual(conversations[0]["anchorText"] as? String, thread.anchorText)
            XCTAssertEqual(conversations[0]["detached"] as? Bool, false)
            XCTAssertEqual(conversations[0]["ephemeral"] as? Bool, true)
            XCTAssertNotNil(conversations[0]["updatedAt"] as? String)

            await handler.handle(BridgeMessage(
                type: "createStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "title": AnyCodable("Does this hold?"),
                    "anchorStart": AnyCodable(1),
                    "anchorEnd": AnyCodable(12),
                    "anchorText": AnyCodable("Power budget")
                ],
                callbackId: "create"
            ))
            let createResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "create" }
            )
            let createdPayload = try XCTUnwrap(createResponse.payload?["thread"]?.value as? [String: Any])
            let createdThreadId = try XCTUnwrap(UUID(uuidString: createdPayload["threadId"] as? String ?? ""))
            XCTAssertEqual(createdPayload["anchorStart"] as? Int, 1)
            XCTAssertEqual(createdPayload["anchorEnd"] as? Int, 12)
            XCTAssertEqual(createdPayload["anchorText"] as? String, "Power budget")
            XCTAssertEqual((createdPayload["exchanges"] as? [[String: Any]])?.count, 0)

            let pinnedAnchorPayload: [[String: Any]] = [[
                "anchorId": "pinned-stream",
                "kind": "stream_quote",
                "quote": "Pinned passage",
                "anchorSpanId": "pm:14:28"
            ]]
            await handler.handle(BridgeMessage(
                type: "addStreamThreadAnchor",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(createdThreadId.uuidString),
                    "anchors": AnyCodable(pinnedAnchorPayload)
                ],
                callbackId: "add-anchor"
            ))
            let addResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "add-anchor" }
            )
            let addedAnchor = try XCTUnwrap(addResponse.payload?["anchor"]?.value as? [String: Any])
            XCTAssertEqual(addedAnchor["anchorStart"] as? Int, 14)
            XCTAssertEqual(addedAnchor["anchorEnd"] as? Int, 28)
            XCTAssertEqual(try service.loadStreamThreadAnchors(
                threadId: createdThreadId,
                streamId: stream.id
            ).map(\.quote), ["Pinned passage"])

            await handler.handle(BridgeMessage(
                type: "removeStreamThreadAnchor",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(createdThreadId.uuidString),
                    "anchorId": AnyCodable("pinned-stream")
                ],
                callbackId: "remove-anchor"
            ))
            let removeResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "remove-anchor" }
            )
            XCTAssertEqual(removeResponse.payload?["removed"]?.value as? Bool, true)
            XCTAssertEqual(try service.loadStreamThreadAnchors(
                threadId: createdThreadId,
                streamId: stream.id
            ), [])

            try service.saveExchange(AIExchange(
                requestId: "conversation-turn",
                streamId: stream.id,
                threadId: createdThreadId,
                verb: "thread",
                userInput: "Does this hold?",
                responseRaw: "Yes."
            ))
            await handler.handle(BridgeMessage(
                type: "loadStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(createdThreadId.uuidString)
                ],
                callbackId: "load"
            ))
            let loadResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "load" }
            )
            let loadedPayload = try XCTUnwrap(loadResponse.payload?["thread"]?.value as? [String: Any])
            let exchanges = try XCTUnwrap(loadedPayload["exchanges"] as? [[String: Any]])
            XCTAssertEqual(exchanges.map { $0["requestId"] as? String }, ["conversation-turn"])
            XCTAssertEqual(exchanges.first?["responseRaw"] as? String, "Yes.")

            await handler.handle(BridgeMessage(
                type: "deleteStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(createdThreadId.uuidString)
                ],
                callbackId: "delete"
            ))
            let deleteResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "delete" }
            )
            XCTAssertEqual(deleteResponse.payload?["highlightIds"]?.value as? [String], [])
            XCTAssertNil(try service.loadStreamThread(threadId: createdThreadId, streamId: stream.id))

            await handler.handle(BridgeMessage(
                type: "saveStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(thread.threadId.uuidString),
                    "title": AnyCodable("Power budget"),
                    "baseRevision": AnyCodable(0)
                ],
                callbackId: "save"
            ))
            let saveResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "save" }
            )
            XCTAssertEqual(saveResponse.payload?["conflict"]?.value as? Bool, false)
            let savedPayload = try XCTUnwrap(saveResponse.payload?["thread"]?.value as? [String: Any])
            XCTAssertEqual(savedPayload["title"] as? String, "Power budget")
            XCTAssertEqual(savedPayload["workingText"] as? String, thread.workingText)
            XCTAssertEqual(savedPayload["docJSON"] as? String, docJSON)
            XCTAssertEqual(savedPayload["revision"] as? Int, 1)
            XCTAssertNotNil(savedPayload["anchors"] as? [[String: Any]])
            XCTAssertNotNil(savedPayload["exchanges"] as? [[String: Any]])

            await handler.handle(BridgeMessage(
                type: "saveStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(thread.threadId.uuidString),
                    "title": AnyCodable("Stale"),
                    "baseRevision": AnyCodable(0)
                ],
                callbackId: "conflict"
            ))
            let conflictResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "conflict" }
            )
            XCTAssertEqual(conflictResponse.payload?["conflict"]?.value as? Bool, true)
            let conflictPayload = try XCTUnwrap(conflictResponse.payload?["thread"]?.value as? [String: Any])
            XCTAssertEqual(conflictPayload["title"] as? String, "Power budget")
            XCTAssertEqual(conflictPayload["workingText"] as? String, thread.workingText)
            XCTAssertNotNil(conflictPayload["anchors"] as? [[String: Any]])
            XCTAssertNotNil(conflictPayload["exchanges"] as? [[String: Any]])

            await handler.handle(BridgeMessage(
                type: "saveStreamThread",
                payload: [
                    "streamId": AnyCodable(otherStream.id.uuidString),
                    "threadId": AnyCodable(thread.threadId.uuidString),
                    "title": AnyCodable("Foreign"),
                    "baseRevision": AnyCodable(1)
                ],
                callbackId: "foreign"
            ))
            let foreignResponse = try XCTUnwrap(
                recorder.messages(ofType: "callback").first { $0.callbackId == "foreign" }
            )
            XCTAssertNotNil(foreignResponse.payload?["error"]?.value as? String)

            await handler.handle(BridgeMessage(
                type: "saveStreamThread",
                payload: [
                    "streamId": AnyCodable(stream.id.uuidString),
                    "threadId": AnyCodable(thread.threadId.uuidString),
                    "title": AnyCodable("Missing callback"),
                    "baseRevision": AnyCodable(1)
                ]
            ))
            XCTAssertEqual(
                recorder.messages(ofType: "bridgeError").last?.payload?["originalType"]?.value as? String,
                "saveStreamThread"
            )
        }
    }

    func test_v21MigrationAddsMarginTablesToFreshDatabase() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let tables = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                ).map { row -> String in row["name"] }
            }
            let indexes = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ).map { row -> String in row["name"] }
            }
            let noteColumns = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(margin_notes)").map { row -> String in
                    row["name"]
                }
            }

            XCTAssertTrue(tables.contains("margin_notes"))
            XCTAssertTrue(tables.contains("margin_suppressions"))
            XCTAssertTrue(indexes.contains("idx_margin_stream"))
            XCTAssertEqual(
                noteColumns,
                ["note_id", "stream_id", "anchor_start", "anchor_end", "anchor_hash", "kind", "body", "body_hash", "request_id", "status", "created_at"]
            )
        }
    }

    func test_fnv1aMatchesSharedVector() {
        XCTAssertEqual(FNV1a.hash("The quick brown fox"), "ae4d67e2")
    }

    func test_utf16OffsetsHandleEmojiRegression() {
        let text = "a🙂b"

        XCTAssertEqual(UTF16Offsets.utf16Length(text), 4)
        XCTAssertEqual(UTF16Offsets.substring(text, start: 3, end: 4), "b")
    }

    func test_provenanceSpansRoundTrip() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Provenance")
            try service.saveStream(stream)
            let spans = [
                ProvenanceSpan(
                    spanId: "span-1",
                    streamId: stream.id,
                    start: 0,
                    end: 5,
                    origin: "ai",
                    requestId: "request-1",
                    sourceId: nil,
                    meta: #"{"model":"test"}"#,
                    textHash: FNV1a.hash("hello"),
                    createdAt: Date(timeIntervalSince1970: 1_234)
                ),
                ProvenanceSpan(
                    spanId: "span-2",
                    streamId: stream.id,
                    start: 8,
                    end: 12,
                    origin: "source",
                    requestId: nil,
                    sourceId: "source-1",
                    meta: #"{"page":2}"#,
                    textHash: FNV1a.hash("note"),
                    createdAt: Date(timeIntervalSince1970: 1_235)
                )
            ]

            try service.replaceSpans(streamId: stream.id, spans: spans)
            XCTAssertEqual(try service.loadSpans(streamId: stream.id), spans)

            try service.replaceSpans(streamId: stream.id, spans: [spans[1]])
            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [spans[1]])
        }
    }

    func test_aiExchangesRoundTripAndDeleteOrphans() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Exchange")
            try service.saveStream(stream)
            let exchange = AIExchange(
                requestId: "request-1",
                streamId: stream.id,
                verb: "develop",
                userInput: "Selection: hello",
                sourceManifest: #"[{"title":"Source"}]"#,
                responseRaw: "Developed response",
                model: "test-model",
                createdAt: Date(timeIntervalSince1970: 1_236)
            )

            try service.saveExchange(exchange)
            XCTAssertEqual(try service.loadExchange(requestId: exchange.requestId), exchange)

            try service.replaceSpans(streamId: stream.id, spans: [
                ProvenanceSpan(
                    spanId: "span-1",
                    streamId: stream.id,
                    start: 0,
                    end: 5,
                    origin: "ai",
                    requestId: exchange.requestId,
                    textHash: FNV1a.hash("hello"),
                    createdAt: Date(timeIntervalSince1970: 1_237)
                )
            ])
            try service.deleteOrphanExchanges(streamId: stream.id)
            XCTAssertEqual(try service.loadExchange(requestId: exchange.requestId), exchange)

            try service.replaceSpans(streamId: stream.id, spans: [])
            try service.deleteOrphanExchanges(streamId: stream.id)
            XCTAssertNil(try service.loadExchange(requestId: exchange.requestId))

            let noteExchange = AIExchange(
                requestId: "request-note",
                streamId: stream.id,
                verb: "challenge",
                userInput: "Selection: premise",
                sourceManifest: "[]",
                responseRaw: "Where is the evidence?",
                model: "test-model",
                createdAt: Date(timeIntervalSince1970: 1_238)
            )
            let note = MarginNote(
                noteId: "note-exchange",
                streamId: stream.id,
                anchorStart: 0,
                anchorEnd: 7,
                anchorHash: FNV1a.hash("premise"),
                kind: "tension",
                body: "Where is the evidence?",
                bodyHash: FNV1a.hash("Where is the evidence?"),
                requestId: noteExchange.requestId,
                createdAt: Date(timeIntervalSince1970: 1_239)
            )
            try service.saveExchange(noteExchange)
            try service.insertMarginNotes([note])
            try service.deleteOrphanExchanges(streamId: stream.id)
            XCTAssertEqual(try service.loadExchange(requestId: noteExchange.requestId), noteExchange)

            try service.deleteMarginNote(noteId: note.noteId)
            try service.deleteOrphanExchanges(streamId: stream.id)
            XCTAssertNil(try service.loadExchange(requestId: noteExchange.requestId))
        }
    }

    func test_marginNotesCRUDAndSuppressionRoundTrip() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Margin")
            try service.saveStream(stream)
            let note = MarginNote(
                noteId: "note-1",
                streamId: stream.id,
                anchorStart: 0,
                anchorEnd: 12,
                anchorHash: FNV1a.hash("anchor words"),
                kind: "question",
                body: "What assumption carries this claim?",
                bodyHash: FNV1a.hash("What assumption carries this claim?"),
                requestId: "request-1",
                createdAt: Date(timeIntervalSince1970: 2_000)
            )

            try service.insertMarginNotes([note])
            XCTAssertEqual(try service.loadMarginNotes(streamId: stream.id), [note])
            XCTAssertEqual(try service.nonDismissedMarginNoteBodyHashes(streamId: stream.id), Set([note.bodyHash]))

            XCTAssertTrue(try service.updateMarginNoteStatus(noteId: note.noteId, status: "dismissed"))
            XCTAssertEqual(try service.loadMarginNotes(streamId: stream.id), [])
            XCTAssertEqual(try service.loadMarginNotes(streamId: stream.id, statuses: nil).first?.status, "dismissed")

            try service.insertMarginSuppression(streamId: stream.id, bodyHash: note.bodyHash)
            XCTAssertEqual(try service.marginSuppressionHashes(streamId: stream.id), Set([note.bodyHash]))

            try service.deleteMarginNote(noteId: note.noteId)
            XCTAssertEqual(try service.loadMarginNotes(streamId: stream.id, statuses: nil), [])
        }
    }

    func test_deleteStreamDeletesMarginSuppressions() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Disposable Margin")
            try service.saveStream(stream)
            try service.insertMarginSuppression(streamId: stream.id, bodyHash: "question-hash")

            try service.deleteStream(id: stream.id)

            XCTAssertEqual(try service.marginSuppressionHashes(streamId: stream.id), [])
        }
    }

    func test_loadStreamSummariesCountsOnlyOpenQuestions() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Questions")
            let otherStream = Stream(title: "Other Questions")
            try service.saveStream(stream)
            try service.saveStream(otherStream)
            try service.insertMarginNotes([
                MarginNote(
                    streamId: stream.id,
                    anchorStart: 0,
                    anchorEnd: 10,
                    anchorHash: FNV1a.hash("first note"),
                    kind: "question",
                    body: "Open question?",
                    bodyHash: FNV1a.hash("Open question?")
                ),
                MarginNote(
                    streamId: stream.id,
                    anchorStart: 11,
                    anchorEnd: 21,
                    anchorHash: FNV1a.hash("second note"),
                    kind: "tension",
                    body: "Open tension.",
                    bodyHash: FNV1a.hash("Open tension.")
                ),
                MarginNote(
                    streamId: stream.id,
                    anchorStart: 22,
                    anchorEnd: 32,
                    anchorHash: FNV1a.hash("third note"),
                    kind: "question",
                    body: "Dismissed question?",
                    bodyHash: FNV1a.hash("Dismissed question?"),
                    status: "dismissed"
                ),
                MarginNote(
                    streamId: otherStream.id,
                    anchorStart: 0,
                    anchorEnd: 10,
                    anchorHash: FNV1a.hash("other note"),
                    kind: "question",
                    body: "Other stream?",
                    bodyHash: FNV1a.hash("Other stream?")
                )
            ])

            let summary = try XCTUnwrap(try service.loadStreamSummaries().first { $0.id == stream.id })
            XCTAssertEqual(summary.openQuestionCount, 1)

            let payload = StreamCodec.encodeSummaries([summary])
            let encodedStreams = try XCTUnwrap(payload["streams"]?.value as? [[String: Any]])
            let encodedSummary = try XCTUnwrap(encodedStreams.first)
            XCTAssertEqual(encodedSummary["openQuestionCount"] as? Int, 1)
        }
    }

    func test_normalizedTextSearchMatchesCurlyQuotesAndCollapsedWhitespace() throws {
        let text = "He said, “the rent\nincrease cannot happen mid term” in the memo."
        let range = try XCTUnwrap(NormalizedTextSearch.utf16Range(
            of: #"said, "the rent increase cannot happen mid term""#,
            in: text
        ))

        XCTAssertEqual(
            UTF16Offsets.substring(text, start: range.lowerBound, end: range.upperBound),
            "said, “the rent\nincrease cannot happen mid term”"
        )
    }

    func test_normalizedTextSearchNoMatchReturnsNil() {
        XCTAssertNil(NormalizedTextSearch.utf16Range(of: "missing phrase", in: "present phrase"))
    }

    func test_getExchangePayloadRoundTripAndSavePrunesOrphans() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Exchange Save")
            try service.saveStream(stream)
            let exchange = AIExchange(
                requestId: "request-save-gc",
                streamId: stream.id,
                verb: "ask",
                userInput: "Selection:\nText\n\nPrompt:\nWhy?",
                sourceManifest: #"[{"chunkId":"chunk-1","sourceId":"source-1","page":2,"shortTitle":"Manual"}]"#,
                responseRaw: "Raw answer",
                model: "provider/model",
                createdAt: Date(timeIntervalSince1970: 1_240)
            )
            try service.saveExchange(exchange)

            let loaded = try XCTUnwrap(try service.loadExchange(requestId: exchange.requestId))
            let encoded = StreamCodec.encodeExchange(loaded)
            XCTAssertEqual(encoded["requestId"] as? String, exchange.requestId)
            XCTAssertEqual(encoded["userInput"] as? String, exchange.userInput)
            XCTAssertEqual(encoded["sourceManifest"] as? String, exchange.sourceManifest)
            XCTAssertEqual(encoded["responseRaw"] as? String, exchange.responseRaw)

            let revision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Text",
                baseRevision: 0,
                spans: [
                    ProvenanceSpan(
                        spanId: "span-1",
                        streamId: stream.id,
                        start: 0,
                        end: 4,
                        origin: "ai",
                        requestId: exchange.requestId,
                        textHash: FNV1a.hash("Text"),
                        createdAt: Date(timeIntervalSince1970: 1_241)
                    )
                ]
            )
            XCTAssertNotNil(try service.loadExchange(requestId: exchange.requestId))

            _ = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Text",
                baseRevision: revision,
                spans: []
            )
            XCTAssertNil(try service.loadExchange(requestId: exchange.requestId))
        }
    }

    func test_provenanceRowsCascadeWhenStreamIsDeleted() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Cascade")
            try service.saveStream(stream)
            let exchange = AIExchange(
                requestId: "request-1",
                streamId: stream.id,
                verb: "ask",
                userInput: "Question",
                responseRaw: "Answer",
                createdAt: Date(timeIntervalSince1970: 1_238)
            )
            try service.saveExchange(exchange)
            try service.replaceSpans(streamId: stream.id, spans: [
                ProvenanceSpan(
                    spanId: "span-1",
                    streamId: stream.id,
                    start: 0,
                    end: 6,
                    origin: "ai",
                    requestId: exchange.requestId,
                    textHash: FNV1a.hash("Answer"),
                    createdAt: Date(timeIntervalSince1970: 1_239)
                )
            ])

            try service.deleteStream(id: stream.id)

            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [])
            XCTAssertNil(try service.loadExchange(requestId: exchange.requestId))
        }
    }

    func test_saveScrollOffsetRoundTripsWithoutBumpingRevision() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scroll Restore")
            try service.saveStream(stream)
            let revision = try service.saveStreamDocument(streamId: stream.id, markdown: "Line one\n\nLine two")
            let before = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))

            try service.saveScrollOffset(streamId: stream.id, offset: 512.5)

            let after = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(revision, 1)
            XCTAssertEqual(after.markdown, before.markdown)
            XCTAssertEqual(after.revision, before.revision)
            XCTAssertEqual(after.updatedAt, before.updatedAt)
            XCTAssertEqual(after.scrollOffset, 512.5)

            let payload = StreamCodec.encodeStream(stream, document: after)
            let documentPayload = try XCTUnwrap(payload["document"] as? [String: Any])
            XCTAssertEqual(documentPayload["scrollOffset"] as? Double, 512.5)
        }
    }

    func test_saveSourceLastPageIndexRoundTripsThroughPersistence() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "PDF Resume")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Manual.pdf",
                fileType: .pdf,
                bookmarkData: Data(),
                status: .ready
            )
            try service.saveSource(source)

            XCTAssertNil(try service.loadSource(id: source.id)?.lastPageIndex)

            try service.saveSourceLastPageIndex(sourceId: source.id, pageIndex: 117)
            XCTAssertEqual(try service.loadSource(id: source.id)?.lastPageIndex, 117)
            XCTAssertEqual(try service.loadStream(id: stream.id)?.sources.first?.lastPageIndex, 117)

            try service.saveSourceLastPageIndex(sourceId: source.id, pageIndex: -4)
            XCTAssertEqual(try service.loadSource(id: source.id)?.lastPageIndex, 0)
        }
    }

    func test_chunkerUsesOutlineSectionPathsAndPageRanges() throws {
        let document = try makePDFDocument(pages: [
            "Opening receipts establish the first page.",
            "Storage receipts include the caliper phrase.",
            "Closing receipts finish the third page."
        ])
        try addOutline(to: document, labels: ["1 Opening", "2 Storage", "3 Closing"])

        let result = try ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            .extractAndChunkPDF(document: document, sourceId: UUID())
        let chunks = result.chunks

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.pageStart), [1, 2, 3])
        XCTAssertEqual(chunks.map(\.pageEnd), [1, 2, 3])
        XCTAssertEqual(chunks.map(\.sectionPath), ["1 Opening", "2 Storage", "3 Closing"])
        XCTAssertTrue(chunks[1].text.contains("caliper phrase"))
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.extractedText.contains("--- Page 2 ---"))
    }

    func test_pdfSectionContextUsesOneIndexedPathForTitleAndOrderedManifest() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Reading")
            try service.saveStream(stream)
            let source = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (2, "Later section text.", 6, 6, "Part I > Storage"),
                    (0, "Opening section text.", 4, 5, "Part I > Storage"),
                    (3, "Different section.", 7, 7, "Part I > Closing"),
                ]
            )
            let retrieval = RetrievalService(persistence: service)

            let resolved = try retrieval.resolvePDFSection(sourceId: source.id, streamId: stream.id, page: 5)
            let assembled = try retrieval.assemblePDFSectionContext(sourceId: source.id, streamId: stream.id, page: 5)

            XCTAssertEqual(resolved.sectionPath, "Part I > Storage")
            XCTAssertEqual(resolved.sectionTitle, "Storage")
            XCTAssertEqual(resolved.pageStart, 4)
            XCTAssertEqual(resolved.pageEnd, 6)
            XCTAssertEqual(assembled.descriptor, resolved)
            XCTAssertEqual(assembled.sourceContext.chunks.map(\.seq), [0, 2])
            XCTAssertEqual(assembled.sourceContext.mode, .retrieved)
            XCTAssertTrue(assembled.sourceContext.text.contains("[1] Manual, p.4–5 (§Part I > Storage):"))
            XCTAssertTrue(assembled.sourceContext.text.contains("[2] Manual, p.6 (§Part I > Storage):"))
        }
    }

    func test_pdfSectionContextRejectsPrivateUnindexedAndUnsectionedSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Reading")
            try service.saveStream(stream)
            let privateSource = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.pdf",
                extractedText: "private",
                aiExcluded: true,
                chunks: [(0, "Private section.", 1, 1, "Private")]
            )
            let pendingSource = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Pending.pdf",
                extractedText: "",
                indexStatus: .indexing
            )
            let flatSource = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Flat.pdf",
                extractedText: "flat",
                chunks: [(0, "Flat text.", 1, 1, nil)]
            )
            let retrieval = RetrievalService(persistence: service)

            XCTAssertThrowsError(try retrieval.resolvePDFSection(sourceId: privateSource.id, streamId: stream.id, page: 1)) {
                XCTAssertEqual($0 as? PDFSectionContextError, .sourceExcluded)
            }
            XCTAssertThrowsError(try retrieval.resolvePDFSection(sourceId: pendingSource.id, streamId: stream.id, page: 1)) {
                XCTAssertEqual($0 as? PDFSectionContextError, .indexing)
            }
            XCTAssertThrowsError(try retrieval.resolvePDFSection(sourceId: flatSource.id, streamId: stream.id, page: 1)) {
                XCTAssertEqual($0 as? PDFSectionContextError, .noSection)
            }
        }
    }

    func test_pdfSectionContextRejectsReferenceMaterialOverRequestBudget() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Reading")
            try service.saveStream(stream)
            let oversized = String(repeating: "x", count: (RetrievalService.maxPDFSectionReferenceTokens + 1) * 4)
            let source = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Long.pdf",
                extractedText: oversized,
                chunks: [(0, oversized, 1, 1, "Long section")]
            )

            XCTAssertThrowsError(
                try RetrievalService(persistence: service)
                    .assemblePDFSectionContext(sourceId: source.id, streamId: stream.id, page: 1)
            ) {
                XCTAssertEqual($0 as? PDFSectionContextError, .sectionTooLong)
            }
        }
    }

    func test_sameNameImageImportsKeepBothAssetsImmutable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try fileManager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstData = try makePNG(red: 255, green: 0, blue: 0)
        let secondData = try makePNG(red: 0, green: 0, blue: 255)
        let firstURL = firstDirectory.appendingPathComponent("image.png")
        let secondURL = secondDirectory.appendingPathComponent("image.png")
        try firstData.write(to: firstURL)
        try secondData.write(to: secondURL)

        let assetService = AssetService(baseDirectory: root.appendingPathComponent("assets", isDirectory: true))
        let streamId = UUID()
        let firstPath = try assetService.saveImage(from: firstURL, streamId: streamId)
        let secondPath = try assetService.saveImage(from: secondURL, streamId: streamId)

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(try Data(contentsOf: assetService.assetURL(for: firstPath)), firstData)
        XCTAssertEqual(try Data(contentsOf: assetService.assetURL(for: secondPath)), secondData)
    }

    func test_recentSavedScreenshotIsCapturedWhenTaggedAndFresh() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let imageData = try makePNG(red: 255, green: 0, blue: 0)
        let screenshotURL = directory.appendingPathComponent("capture.png")
        try imageData.write(to: screenshotURL)

        let marker = Data([1])
        let result = screenshotURL.withUnsafeFileSystemRepresentation { path in
            marker.withUnsafeBytes { bytes in
                setxattr(
                    path,
                    "com.apple.metadata:kMDItemIsScreenCapture",
                    bytes.baseAddress,
                    marker.count,
                    0,
                    0
                )
            }
        }
        XCTAssertEqual(result, 0)

        let now = Date()
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: screenshotURL.path)
        XCTAssertEqual(
            ClipboardService.getRecentScreenshotData(in: directory, maxAge: 10, now: now),
            imageData
        )

        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-11)],
            ofItemAtPath: screenshotURL.path
        )
        XCTAssertNil(ClipboardService.getRecentScreenshotData(in: directory, maxAge: 10, now: now))
    }

    func test_clipboardImageKeepsItsNativePNGData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TickerImagePasteboardTests.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let imageData = try makePNG(red: 0, green: 0, blue: 255)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(imageData, forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(ClipboardService.getImageData(pasteboard: pasteboard), imageData)
    }

    @MainActor
    func test_quickPanelImageBecomesProxyVisionPart() throws {
        let imageData = try makePNG(red: 255, green: 0, blue: 0)
        let assetService = AssetService(baseDirectory: FileManager.default.temporaryDirectory)
        let imageURLs = try QuickPanelManager.imageDataURLsForAI(imageData, using: assetService)
        let request = LLMRequest(
            systemPrompt: "Test",
            messages: [LLMMessage(role: "user", content: "Describe this", imageURLs: imageURLs)]
        )

        let messages = ProxyLLMService().buildProxyMessages(from: request)
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.last?["source"] as? [String: String])

        XCTAssertEqual(content.first?["text"] as? String, "Describe this")
        XCTAssertEqual(image["type"], "base64")
        XCTAssertEqual(image["media_type"], "image/png")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(image["data"])), imageData)
        XCTAssertThrowsError(
            try QuickPanelManager.imageDataURLsForAI(Data("not an image".utf8), using: assetService)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Attached image could not be prepared for AI")
        }
    }

    func test_imageImportRejectsOversizedBytesAndDimensions() throws {
        let assetService = AssetService(baseDirectory: FileManager.default.temporaryDirectory)

        XCTAssertThrowsError(
            try assetService.saveImage(
                data: Data(count: ImageImportPolicy.maxByteCount + 1),
                streamId: UUID()
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Images must be 25 MB or smaller.")
        }

        let tooWide = try makePNG(
            width: ImageImportPolicy.maxPixelDimension + 1,
            red: 0,
            green: 0,
            blue: 0
        )
        XCTAssertThrowsError(try assetService.saveImage(data: tooWide, streamId: UUID())) { error in
            XCTAssertEqual(error.localizedDescription, "That image's dimensions are too large.")
        }
    }

    func test_sourceChunksAndFTSRowsAreRemovedWhenSourceIsDeleted() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let source = try savePDFSource(in: service)
            let chunk = SourceChunk(
                sourceId: source.id,
                seq: 0,
                text: "The ultraviolet caliper phrase should be found by FTS.",
                pageStart: 1,
                pageEnd: 1,
                sectionPath: "Fixtures"
            )

            try service.saveSourceChunks([chunk], for: source.id)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let matches = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT c.text
                        FROM source_chunks_fts
                        JOIN source_chunks c ON c.id = source_chunks_fts.chunk_id
                        WHERE source_chunks_fts MATCH ?
                    """,
                    arguments: ["ultraviolet"]
                ).map { row -> String in row["text"] }
            }

            XCTAssertEqual(matches, [chunk.text])

            try service.deleteSource(id: source.id)

            let counts = try dbQueue.read { db in
                let chunkCount: Int = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS count FROM source_chunks WHERE source_id = ?",
                    arguments: [source.id.uuidString]
                )?["count"] ?? -1
                let ftsCount: Int = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS count FROM source_chunks_fts WHERE source_id = ?",
                    arguments: [source.id.uuidString]
                )?["count"] ?? -1
                return (chunkCount, ftsCount)
            }

            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 0)
        }
    }

    func test_loadSourceChunkReturnsSingleChunkById() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let first = SourceChunk(
                sourceId: source.id,
                seq: 0,
                text: "First chunk text.",
                pageStart: 1,
                pageEnd: 1
            )
            let second = SourceChunk(
                sourceId: source.id,
                seq: 1,
                text: "Second chunk text.",
                pageStart: 2,
                pageEnd: 2
            )

            try service.saveSourceChunks([first, second], for: source.id)

            let loaded = try XCTUnwrap(service.loadSourceChunk(id: second.id))
            XCTAssertEqual(loaded.id, second.id)
            XCTAssertEqual(loaded.sourceId, second.sourceId)
            XCTAssertEqual(loaded.seq, second.seq)
            XCTAssertEqual(loaded.text, second.text)
            XCTAssertEqual(loaded.pageStart, second.pageStart)
            XCTAssertEqual(loaded.pageEnd, second.pageEnd)
            XCTAssertEqual(loaded.sectionPath, second.sectionPath)
            XCTAssertNil(try service.loadSourceChunk(id: UUID()))
        }
    }

    func test_retrievalSingleSourceFloorReturnsBestChunkForWeakQuery() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Large Source")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed as the best fallback.", 4, 4, "Storage")
                ]
            )

            let retrieval = RetrievalService(persistence: service)

            let weakQuery = "what is the best way to do this"
            let rawResults = try retrieval.retrieve(query: weakQuery, streamId: stream.id, applyThreshold: false)

            XCTAssertFalse(rawResults.isEmpty)
            XCTAssertTrue(try retrieval.retrieve(query: weakQuery, streamId: stream.id).isEmpty)

            // H1.1: one content source plus a weak lexical candidate is user intent, not no-context.
            let context = try XCTUnwrap(
                retrieval.assembleSourceContext(query: weakQuery, streamId: stream.id)
            )
            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Manual.pdf"])
            XCTAssertTrue(context.text.contains("Storage manifolds and caliper fixtures"))
        }
    }

    func test_hybridRetrievalAppliesCosineFloor() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Semantic floor")
            try service.saveStream(stream)
            let source = try saveRetrievalSource(
                in: service, streamId: stream.id, displayName: "Concepts.pdf",
                extractedText: largeExtractedText(), chunks: [(0, "orthogonal source wording", 1, 1, nil)]
            )
            let chunk = try XCTUnwrap(service.loadSourceChunks(sourceId: source.id).first)
            try service.saveChunkEmbeddings([[0.4, 0.9165]], for: [chunk], modelId: "test-model")
            let provider = TestEmbeddingProvider { _ in [[1, 0]] }

            let gated = RetrievalService(
                persistence: service, embeddingProvider: provider,
                operatingPoint: .init(cosineFloor: 0.5, rrfK: 60)
            )
            let passing = RetrievalService(
                persistence: service, embeddingProvider: provider,
                operatingPoint: .init(cosineFloor: 0.3, rrfK: 60)
            )

            XCTAssertTrue(try gated.retrieve(query: "conceptual question", streamId: stream.id).isEmpty)
            XCTAssertEqual(try passing.retrieve(query: "conceptual question", streamId: stream.id).map(\.id), [chunk.id])
        }
    }

    func test_reciprocalRankFusionOrder() {
        XCTAssertNotNil(RetrievalOperatingPoint.bundled())
        XCTAssertEqual(
            RetrievalService.reciprocalRankFuse(
                bm25: ["a", "b"], semantic: ["b", "c"], rrfK: 60, limit: 3
            ),
            ["b", "a", "c"]
        )
    }

    func test_semanticBudgetOrFailureFallsBackToExactBM25() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Budget fallback")
            try service.saveStream(stream)
            let source = try saveRetrievalSource(
                in: service, streamId: stream.id, displayName: "Lexical.pdf",
                extractedText: largeExtractedText(), chunks: [(0, "anvil anvil anvil receipt", 1, 1, nil)]
            )
            let chunk = try XCTUnwrap(service.loadSourceChunks(sourceId: source.id).first)
            try service.saveChunkEmbeddings([[1, 0]], for: [chunk], modelId: "test-model")
            let baseline = try RetrievalService(persistence: service)
                .retrieve(query: "anvil receipt", streamId: stream.id)
            let slow = TestEmbeddingProvider { _ in
                Thread.sleep(forTimeInterval: 0.05)
                return [[1, 0]]
            }
            let actual = try RetrievalService(
                persistence: service, embeddingProvider: slow,
                operatingPoint: .init(cosineFloor: 0.3, rrfK: 60),
                queryBudget: 0.001
            ).retrieve(query: "anvil receipt", streamId: stream.id)
            let failed = try RetrievalService(
                persistence: service,
                embeddingProvider: TestEmbeddingProvider { _ in
                    throw NSError(domain: "RetrievalTest", code: 1)
                },
                operatingPoint: .init(cosineFloor: 0.3, rrfK: 60)
            ).retrieve(query: "anvil receipt", streamId: stream.id)

            XCTAssertEqual(actual.map(\.id), baseline.map(\.id))
            XCTAssertEqual(actual.map(\.score), baseline.map(\.score))
            XCTAssertEqual(failed.map(\.id), baseline.map(\.id))
            XCTAssertEqual(failed.map(\.score), baseline.map(\.score))
        }
    }

    func test_retrievalTermCoverageFiltersBeforeTopK() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Coverage Before Limit")
            try service.saveStream(stream)
            let rareTerms = (0..<8).map { "rareterm\($0)" }
            let distractors: [RetrievalChunkFixture] = rareTerms.enumerated().map { index, term in
                (index, String(repeating: "\(term) ", count: 80), index + 1, index + 1, nil)
            }
            let sharedFillers: [RetrievalChunkFixture] = (0..<100).map { index in
                let term = index < 50 ? "sharedalpha" : "sharedbeta"
                return (100 + index, "\(term) filler \(index)", 100 + index, 100 + index, nil)
            }
            let genericFillers: [RetrievalChunkFixture] = (0..<1_000).map { index in
                (1_000 + index, "unrelated filler document \(index)", 1_000 + index, 1_000 + index, nil)
            }
            let relevantText = String(repeating: "sharedalpha sharedbeta ", count: 40)
            let source = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Coverage.pdf",
                extractedText: largeExtractedText(),
                chunks: distractors + sharedFillers + genericFillers + [(999, relevantText, 999, 999, nil)]
            )
            let relevantID = try XCTUnwrap(
                service.loadSourceChunks(sourceId: source.id).first { $0.seq == 999 }?.id
            )
            let query = (rareTerms + ["sharedalpha", "sharedbeta"]).joined(separator: " ")
            let retrieval = RetrievalService(persistence: service)

            XCTAssertFalse(
                try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
                    .contains { $0.id == relevantID }
            )
            XCTAssertEqual(
                try retrieval.retrieve(query: query, streamId: stream.id).map(\.id),
                [relevantID]
            )
        }
    }

    func test_retrievalSingleSourceFloorReturnsBestChunkWhenAllQueryTokensMatchOnlyWeakly() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Weak Matches")
            try service.saveStream(stream)
            let weakChunks = weakUnrelatedChunks()
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Technical.pdf",
                extractedText: largeExtractedText(),
                chunks: weakChunks
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "good dish party friends"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let cutoff = -1.0 * Double(sanitized.tokenCount)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let corpusText = weakChunks.map(\.text).joined(separator: " ")

            XCTAssertEqual(sanitized.tokenCount, 4)
            XCTAssertTrue(["good", "dish", "party", "friends"].allSatisfy { corpusText.contains($0) })
            XCTAssertLessThan(bestScore, 0)
            XCTAssertGreaterThan(bestScore, cutoff)
            XCTAssertTrue(try retrieval.retrieve(query: query, streamId: stream.id).isEmpty)

            // H1.1: the single-source floor deliberately abandoned the old nil here.
            let context = try XCTUnwrap(
                retrieval.assembleSourceContext(query: query, streamId: stream.id)
            )
            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertFalse(context.chunks.isEmpty)
            XCTAssertTrue(context.chunks.allSatisfy { $0.sourceName == "Technical.pdf" })
        }
    }

    func test_retrievalSingleSourceFloorStillGatesZeroVocabularyQuery() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Zero Vocabulary")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed here.", 4, 4, "Storage")
                ]
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "orchid saxophone nebula"
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)

            XCTAssertTrue(rawResults.isEmpty)
            XCTAssertNil(try retrieval.assembleSourceContext(query: query, streamId: stream.id))
        }
    }

    func test_retrievalMultiSourceWeakMatchesStillGateAutoContext() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Weak Multi Source")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Alpha.pdf",
                extractedText: largeExtractedText("alpha"),
                chunks: weakUnrelatedChunks()
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Beta.pdf",
                extractedText: largeExtractedText("beta"),
                chunks: weakUnrelatedChunks()
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "good dish party friends"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let cutoff = -1.0 * Double(sanitized.tokenCount)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)

            XCTAssertFalse(rawResults.isEmpty)
            XCTAssertGreaterThan(bestScore, cutoff)
            XCTAssertTrue(try retrieval.retrieve(query: query, streamId: stream.id).isEmpty)
            XCTAssertNil(try retrieval.assembleSourceContext(query: query, streamId: stream.id))
        }
    }

    func test_retrievalMultiSourceStrongMatchRetrievesConfidentChunk() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Strong Multi Source")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Lease.pdf",
                extractedText: largeExtractedText("lease"),
                chunks: stronglyRelevantChunks(
                    strongText: "termination termination termination lease lease lease option option option",
                    pageStart: 7,
                    pageEnd: 7
                )
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Appendix.pdf",
                extractedText: largeExtractedText("appendix"),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed here.", 4, 4, "Storage")
                ]
            )

            let retrieval = RetrievalService(persistence: service)
            let context = try XCTUnwrap(
                retrieval.assembleSourceContext(query: "termination lease option", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Lease.pdf"])
            XCTAssertTrue(context.text.contains("termination termination termination"))
        }
    }

    func test_retrievalKeepsStrongMatchesAbovePerTokenCutoff() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Strong Match")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Interpreter.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "interpreter interpreter interpreter numeric numeric numeric conversion conversion conversion input input input",
                    pageStart: 9,
                    pageEnd: 9
                )
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "interpreter numeric conversion input"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let cutoff = -1.0 * Double(sanitized.tokenCount)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let results = try retrieval.retrieve(query: query, streamId: stream.id)

            XCTAssertEqual(sanitized.tokenCount, 4)
            XCTAssertLessThanOrEqual(bestScore, cutoff)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.sourceName, "Interpreter.pdf")
        }
    }

    func test_retrievalCapsPerTokenCutoffForLongParagraphQueries() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Long Query")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Interpreter.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "interpreter interpreter interpreter numeric numeric numeric",
                    pageStart: 10,
                    pageEnd: 10
                )
            )

            let retrieval = RetrievalService(persistence: service)
            let query = "interpreter numeric conversion input handle source cursor paragraph manual chapter section reader"
            let sanitized = try XCTUnwrap(RetrievalService.sanitizedFTSQuery(query))
            let uncappedCutoff = -1.0 * Double(sanitized.tokenCount)
            let cappedCutoff = -1.0 * Double(8)
            let rawResults = try retrieval.retrieve(query: query, streamId: stream.id, applyThreshold: false)
            let bestScore = try XCTUnwrap(rawResults.first?.score)
            let results = try retrieval.retrieve(query: query, streamId: stream.id)

            XCTAssertEqual(sanitized.tokenCount, 12)
            XCTAssertGreaterThan(bestScore, uncappedCutoff)
            XCTAssertLessThanOrEqual(bestScore, cappedCutoff)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.sourceName, "Interpreter.pdf")
        }
    }

    func test_retrievalSourceScopeNoneReturnsNoContextEvenWithMatchingChunks() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scope None")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Storage manifolds and caliper fixtures are indexed here.", 4, 4, "Storage")
                ]
            )

            let context = try RetrievalService(persistence: service)
                .assembleSourceContext(query: "storage manifold", streamId: stream.id, scope: .none)

            XCTAssertNil(context)
        }
    }

    func test_retrievalSourceScopeAllReturnsWeakMatchesBelowAutoThreshold() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Scope All")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Weak.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "weakterm " + String(repeating: "filler ", count: 30), 5, 5, nil),
                    (1, String(repeating: "other filler ", count: 10), 6, 6, nil)
                ]
            )

            let retrieval = RetrievalService(persistence: service)

            XCTAssertTrue(try retrieval.retrieve(query: "weakterm", streamId: stream.id).isEmpty)

            let context = try XCTUnwrap(
                retrieval.assembleSourceContext(query: "weakterm", streamId: stream.id, scope: .all)
            )
            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Weak.pdf"])
            XCTAssertTrue(context.text.contains("[1] Weak, p.5:"))
        }
    }

    func test_retrievalPassthroughUsesLegacyWholeTextFormatForSmallSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Small Sources")
            try service.saveStream(stream)
            let first = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "One.txt",
                extractedText: "First source text",
                indexStatus: .pending,
                addedAt: Date(timeIntervalSince1970: 1)
            )
            let second = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Two.txt",
                extractedText: "Second source text",
                indexStatus: .ready,
                addedAt: Date(timeIntervalSince1970: 2)
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "anything", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .passthrough)
            XCTAssertEqual(context.text, "First source text\n\n---\n\nSecond source text")
            XCTAssertEqual(context.sourceIds, [first.id, second.id])
        }
    }

    func test_retrievalPassthroughOmitsAIExcludedSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Private Small Sources")
            try service.saveStream(stream)
            let privateSource = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.txt",
                extractedText: "Private source text",
                aiExcluded: true,
                addedAt: Date(timeIntervalSince1970: 1)
            )
            let publicSource = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Public.txt",
                extractedText: "Public source text",
                addedAt: Date(timeIntervalSince1970: 2)
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "anything", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .passthrough)
            XCTAssertEqual(context.text, "Public source text")
            XCTAssertFalse(context.text.contains("Private source text"))
            XCTAssertEqual(context.sourceIds, [publicSource.id])
            XCTAssertFalse(context.sourceIds.contains(privateSource.id))
        }
    }

    func test_retrievalReturnsNilContextWhenAllSourcesAreAIExcluded() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "All Private")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.txt",
                extractedText: "Private source text",
                aiExcluded: true
            )

            let context = try RetrievalService(persistence: service)
                .assembleSourceContext(query: "anything", streamId: stream.id)

            XCTAssertNil(context)
        }
    }

    func test_retrievalInterleavesMultipleSourcesByScore() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Multiple Sources")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Alpha.pdf",
                extractedText: largeExtractedText("alpha"),
                chunks: stronglyRelevantChunks(
                    strongText: "caliper caliper caliper storage storage storage manifold manifold manifold",
                    pageStart: 2,
                    pageEnd: 2
                )
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Beta.pdf",
                extractedText: largeExtractedText("beta"),
                chunks: stronglyRelevantChunks(
                    strongText: "caliper caliper storage storage manifold manifold",
                    pageStart: 8,
                    pageEnd: 8
                )
            )

            let results = try RetrievalService(persistence: service)
                .retrieve(query: "caliper storage manifold", streamId: stream.id)

            XCTAssertEqual(results.map(\.sourceName), ["Alpha.pdf", "Beta.pdf"])
            XCTAssertLessThanOrEqual(results[0].score, results[1].score)
        }
    }

    func test_retrievalChunksExcludeAIPrivateSourcesAndFillFromAllowedSources() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Private Retrieval")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.pdf",
                extractedText: largeExtractedText("private"),
                aiExcluded: true,
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold private private private",
                    pageStart: 3,
                    pageEnd: 3
                )
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Allowed.pdf",
                extractedText: largeExtractedText("allowed"),
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold allowed allowed allowed",
                    pageStart: 9,
                    pageEnd: 9
                )
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "storage manifold", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.chunks.map(\.sourceName), ["Allowed.pdf"])
            XCTAssertTrue(context.text.contains("allowed allowed allowed"))
            XCTAssertFalse(context.text.contains("private private private"))
        }
    }

    func test_retrievalSanitizesQuerySyntaxWithoutThrowing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Sanitize")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Syntax.pdf",
                extractedText: largeExtractedText(),
                chunks: [
                    (0, "Quotes and parens appear in this chunk.", 1, 1, nil)
                ]
            )

            XCTAssertNoThrow(
                try RetrievalService(persistence: service)
                    .retrieve(query: #""quotes" AND (parens) don't-crash"#, streamId: stream.id)
            )
        }
    }

    func test_retrievalManifestIncludesNumbersSourcePagesAndSection() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Manifest")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: stronglyRelevantChunks(
                    strongText: "storage storage storage manifold manifold manifold receipts receipts receipts",
                    pageStart: 12,
                    pageEnd: 14,
                    sectionPath: "3.2 Storage"
                )
            )

            let context = try XCTUnwrap(
                RetrievalService(persistence: service)
                    .assembleSourceContext(query: "storage manifold receipts", streamId: stream.id)
            )

            XCTAssertEqual(context.mode, .retrieved)
            XCTAssertEqual(context.text, """
            [1] Manual, p.12–14 (§3.2 Storage):
            storage storage storage manifold manifold manifold receipts receipts receipts
            """)
        }
    }

    func test_ingestServiceIndexesPDFAndEmitsStatusTransitions() throws {
        try withTempPersistenceServiceAndURL { service, _, fileManager in
            let stream = Stream(title: "Ingest Ready")
            try service.saveStream(stream)

            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { _ = try? fileManager.removeItem(at: tempDir) }

            let pdfURL = tempDir.appendingPathComponent("Ready.pdf")
            try makePDFData(pages: ["Ready receipt text with the anvil phrase."]).write(to: pdfURL)

            let sourceService = SourceService(persistence: service)
            let source = try sourceService.addSource(from: pdfURL, to: stream.id)
            XCTAssertEqual(source.status, .pending)
            XCTAssertNil(source.extractedText)
            let ingestService = IngestService(
                persistence: service,
                sourceService: sourceService,
                chunkingService: ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            )

            let ready = expectation(description: "source indexed")
            let lock = NSLock()
            var statuses: [SourceIndexStatus] = []
            ingestService.onStatusChange = { update in
                lock.lock()
                statuses.append(update.status)
                lock.unlock()
                if update.status == .ready {
                    ready.fulfill()
                }
            }

            ingestService.enqueue(source: source)
            wait(for: [ready], timeout: 5)

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(reloaded.indexStatus, .ready)
            XCTAssertEqual(reloaded.status, .ready)
            XCTAssertEqual(reloaded.pageCount, 1)
            XCTAssertTrue(reloaded.extractedText?.contains("anvil phrase") == true)
            XCTAssertFalse(try service.loadSourceChunks(sourceId: source.id).isEmpty)
            lock.lock()
            let capturedStatuses = statuses
            lock.unlock()
            XCTAssertTrue(capturedStatuses.contains(.indexing))
            XCTAssertTrue(capturedStatuses.contains(.ready))
        }
    }

    func test_ingestServiceIndexesExtractedTextMarkdownAndOCR() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Non-PDF Ingest")
            try service.saveStream(stream)
            let sources = [
                SourceReference(
                    streamId: stream.id,
                    displayName: "Notes.txt",
                    fileType: .text,
                    bookmarkData: Data(),
                    status: .ready,
                    extractedText: "Plain text remains retrievable after passthrough limits."
                ),
                SourceReference(
                    streamId: stream.id,
                    displayName: "Notes.md",
                    fileType: .markdown,
                    bookmarkData: Data(),
                    status: .ready,
                    extractedText: "# Markdown\n\nIndexed markdown remains retrievable."
                ),
                SourceReference(
                    streamId: stream.id,
                    displayName: "Scan.png",
                    fileType: .image,
                    bookmarkData: Data(),
                    status: .ready,
                    extractedText: "Recognized image text remains retrievable."
                )
            ]
            try sources.forEach(service.saveSource)

            let ingest = IngestService(
                persistence: service,
                sourceService: SourceService(persistence: service),
                chunkingService: ChunkingService(config: .init(targetTokens: 20, overlapTokens: 0))
            )
            let ready = expectation(description: "all non-PDF sources indexed")
            ready.expectedFulfillmentCount = sources.count
            ingest.onStatusChange = { update in
                if update.status == .ready { ready.fulfill() }
            }

            sources.forEach(ingest.enqueue)
            wait(for: [ready], timeout: 5)

            for source in sources {
                XCTAssertEqual(try service.loadSource(id: source.id)?.indexStatus, .ready)
                XCTAssertFalse(try service.loadSourceChunks(sourceId: source.id).isEmpty)
            }
        }
    }

    func test_v23MigrationCreatesEmptyChunkEmbeddingCache() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let columns: [String] = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(chunk_embeddings)").map { $0["name"] }
            }
            let count = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_embeddings")!
            }
            XCTAssertEqual(columns, ["chunk_id", "model_id", "dims", "vector"])
            XCTAssertEqual(count, 0)
        }
    }

    func test_v26AndV27MigrationsAddCanonicalDocumentAndDurableAppendReceipts() throws {
        try withTempPersistenceServiceAndURL { _, dbURL, _ in
            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let documentColumns: [String] = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(stream_documents)").map { $0["name"] }
            }
            let inboxColumns: [String] = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(stream_append_inbox)").map { $0["name"] }
            }
            let indexes: [String] = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ).map { $0["name"] }
            }

            XCTAssertEqual(Array(documentColumns.suffix(2)), ["doc_json", "doc_format_version"])
            XCTAssertEqual(
                inboxColumns,
                ["seq", "append_id", "stream_id", "fragment", "raw_spans_json", "created_at", "consumed_at"]
            )
            XCTAssertTrue(indexes.contains("idx_append_inbox_stream"))
        }
    }

    func test_v26MigrationRefusesHalfWrittenCanonicalDocument() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Canonical pair")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "Before conversion")

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            try dbQueue.write { db in
                XCTAssertThrowsError(try db.execute(
                    sql: "UPDATE stream_documents SET doc_json = ? WHERE stream_id = ?",
                    arguments: [#"{"type":"doc","content":[]}"#, stream.id.uuidString]
                ))

                XCTAssertNoThrow(try db.execute(
                    sql: """
                        UPDATE stream_documents
                        SET doc_json = ?, doc_format_version = 1
                        WHERE stream_id = ?
                    """,
                    arguments: [#"{"type":"doc","content":[]}"#, stream.id.uuidString]
                ))

                XCTAssertThrowsError(try db.execute(
                    sql: "UPDATE stream_documents SET doc_format_version = NULL WHERE stream_id = ?",
                    arguments: [stream.id.uuidString]
                ))
            }
        }
    }

    func test_v26AppendInboxOrdersAppendsAndRejectsReusedIdentity() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let first = Stream(title: "First")
            let second = Stream(title: "Second")
            try service.saveStream(first)
            try service.saveStream(second)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES ('append-1', ?, 'one', 1000), ('append-2', ?, 'two', 1000)
                    """,
                    arguments: [first.id.uuidString, first.id.uuidString]
                )

                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT seq, raw_spans_json FROM stream_append_inbox ORDER BY seq"
                )
                XCTAssertEqual(rows.map { $0["seq"] as Int }, [1, 2])
                XCTAssertEqual(rows.map { $0["raw_spans_json"] as String }, ["[]", "[]"])

                XCTAssertThrowsError(try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES ('append-1', ?, 'different', 1001)
                    """,
                    arguments: [second.id.uuidString]
                ))

                try db.execute(sql: "DELETE FROM streams WHERE id = ?", arguments: [first.id.uuidString])
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_append_inbox"),
                    0
                )
            }
        }
    }

    func test_modelIdMismatchIsMissingEmbedding() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Model mismatch")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id, displayName: "Notes.txt", fileType: .text,
                bookmarkData: Data(), status: .ready, indexStatus: .ready
            )
            try service.saveSource(source)
            let chunk = SourceChunk(sourceId: source.id, seq: 0, text: "cached text", pageStart: 1, pageEnd: 1)
            try service.saveSourceChunks([chunk], for: source.id)
            try service.saveChunkEmbeddings([[1, 0]], for: [chunk], modelId: "old-model")

            XCTAssertEqual(
                try service.loadChunksMissingEmbeddings(streamId: stream.id, modelId: "new-model").map(\.id),
                [chunk.id]
            )
            XCTAssertTrue(try service.loadChunksMissingEmbeddings(streamId: stream.id, modelId: "old-model").isEmpty)
        }
    }

    func test_ingestEmbeddingFailureLeavesFTSReady() throws {
        try withTempPersistenceServiceAndURL { service, _, fileManager in
            let stream = Stream(title: "Embedding failure")
            try service.saveStream(stream)
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempDir) }
            let pdfURL = tempDir.appendingPathComponent("Ready.pdf")
            try makePDFData(pages: ["FTS survives an embedding provider failure."]).write(to: pdfURL)
            let sourceService = SourceService(persistence: service)
            let source = try sourceService.addSource(from: pdfURL, to: stream.id)
            let embeddingAttempted = expectation(description: "embedding attempted")
            let provider = TestEmbeddingProvider { _ in
                embeddingAttempted.fulfill()
                throw TestPDFError.creationFailed
            }
            let ingest = IngestService(
                persistence: service,
                sourceService: sourceService,
                chunkingService: ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0)),
                embeddingProvider: provider
            )
            let ready = expectation(description: "FTS ready")
            ingest.onStatusChange = { if $0.status == .ready { ready.fulfill() } }

            ingest.enqueue(source: source)
            wait(for: [ready, embeddingAttempted], timeout: 5)

            XCTAssertEqual(try service.loadSource(id: source.id)?.indexStatus, .ready)
            XCTAssertFalse(try service.loadSourceChunks(sourceId: source.id).isEmpty)
            XCTAssertFalse(try service.loadChunksMissingEmbeddings(streamId: stream.id, modelId: provider.modelId).isEmpty)
        }
    }

    func test_ingestServiceMarksNoTextPDFAsFailedNoText() throws {
        try withTempPersistenceServiceAndURL { service, _, fileManager in
            let stream = Stream(title: "Ingest No Text")
            try service.saveStream(stream)

            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { _ = try? fileManager.removeItem(at: tempDir) }

            let pdfURL = tempDir.appendingPathComponent("Blank.pdf")
            try makePDFData(pages: [""]).write(to: pdfURL)

            let sourceService = SourceService(persistence: service)
            let source = try sourceService.addSource(from: pdfURL, to: stream.id)
            let ingestService = IngestService(
                persistence: service,
                sourceService: sourceService,
                chunkingService: ChunkingService(config: .init(targetTokens: 200, overlapTokens: 0))
            )

            let failed = expectation(description: "source failed without text")
            ingestService.onStatusChange = { update in
                if update.status == .failedNoText {
                    failed.fulfill()
                }
            }

            ingestService.enqueue(source: source)
            wait(for: [failed], timeout: 5)

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(reloaded.indexStatus, .failedNoText)
            XCTAssertTrue(try service.loadSourceChunks(sourceId: source.id).isEmpty)
        }
    }

    func test_ingestServiceFallsBackToFailedWhenReadyStatusCannotPersist() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Terminal Status")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Notes.txt",
                fileType: .text,
                bookmarkData: Data(),
                status: .ready,
                extractedText: "Terminal status fixture"
            )
            try service.saveSource(source)

            var readyAttempts = 0
            let ingestService = IngestService(
                persistence: service,
                sourceService: SourceService(persistence: service),
                chunkingService: ChunkingService(),
                writeIndexStatus: { sourceId, status in
                    if status == .ready {
                        readyAttempts += 1
                        throw TestPDFError.creationFailed
                    }
                    try service.updateSourceIndexStatus(sourceId, status: status)
                }
            )
            let failed = expectation(description: "terminal status fell back to failed")
            ingestService.onStatusChange = { update in
                if update.status == .failed {
                    failed.fulfill()
                }
            }

            ingestService.enqueue(source: source)
            wait(for: [failed], timeout: 5)

            XCTAssertEqual(readyAttempts, 2)
            XCTAssertEqual(try service.loadSource(id: source.id)?.indexStatus, .failed)
        }
    }

    func test_ingestServiceStopsRetryingWhenStatusStorageKeepsFailing() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Bounded Status Retry")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Notes.txt",
                fileType: .text,
                bookmarkData: Data(),
                status: .ready,
                extractedText: "Bounded retry fixture"
            )
            try service.saveSource(source)

            let lock = NSLock()
            var attempts = 0
            let ingest = IngestService(
                persistence: service,
                sourceService: SourceService(persistence: service),
                chunkingService: ChunkingService(),
                writeIndexStatus: { _, _ in
                    lock.lock()
                    attempts += 1
                    lock.unlock()
                    throw TestPDFError.creationFailed
                }
            )
            let failed = expectation(description: "storage failure surfaced")
            ingest.onStatusChange = { update in
                if update.status == .failed { failed.fulfill() }
            }

            ingest.enqueue(source: source)
            wait(for: [failed], timeout: 2)

            lock.lock()
            let finalAttempts = attempts
            lock.unlock()
            XCTAssertEqual(finalAttempts, 3)
        }
    }

    func test_savePDFHighlightRoundTripsRects() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 2,
                rects: [
                    PDFHighlightRect(page: 2, x: 10.5, y: 20.25, w: 120, h: 14),
                    PDFHighlightRect(page: 3, x: 11, y: 30, w: 98.75, h: 16.5),
                ],
                quote: "Important quoted text",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [highlight])
        }
    }

    func test_sourceAccessRecoversCorruptedBookmarkFromOriginalPath() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("Recovered.pdf")
        try Data("%PDF-1.4\n%EOF\n".utf8).write(to: fileURL)
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        try withTempPersistenceService { service in
            let stream = Stream(title: "Bookmark Recovery")
            try service.saveStream(stream)
            let source = SourceReference(
                streamId: stream.id,
                displayName: "Recovered.pdf",
                fileType: .pdf,
                bookmarkData: Data("not-a-bookmark".utf8),
                originalPath: fileURL.path,
                status: .stale,
                extractedText: "cached text"
            )
            try service.saveSource(source)

            let sourceService = SourceService(persistence: service)
            let recoveredURL = try sourceService.accessFile(source)
            defer { recoveredURL.stopAccessingSecurityScopedResource() }

            let reloaded = try XCTUnwrap(service.loadSource(id: source.id))
            XCTAssertEqual(recoveredURL.path, fileURL.path)
            XCTAssertEqual(reloaded.originalPath, fileURL.path)
            XCTAssertNotEqual(reloaded.bookmarkData, source.bookmarkData)
            XCTAssertEqual(reloaded.status, .ready)
        }
    }

    func test_savePDFPointAnchorRoundTripsEmptyQuoteAndMarkerRect() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let anchor = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 4,
                rects: [PDFHighlightRect(page: 4, x: 42, y: 84, w: 14, h: 14)],
                quote: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )

            try service.savePDFHighlight(anchor)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [anchor])
        }
    }

    func test_deletePDFHighlightIsLimitedToItsStream() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let otherSource = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "Remove me",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)

            XCTAssertFalse(try service.deletePDFHighlight(
                id: highlight.id,
                streamId: otherSource.streamId
            ))
            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [highlight])
            XCTAssertTrue(try service.deletePDFHighlight(
                id: highlight.id,
                streamId: source.streamId
            ))
            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [])
        }
    }

    func test_deleteSourceDeletesPDFHighlights() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "Remove me",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)
            try service.deleteSource(id: source.id)

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [])
        }
    }

    func test_saveStreamDocumentPreservesUnreferencedPDFHighlightsForUndo() throws {
        try withTempPersistenceService { service in
            let source = try savePDFSource(in: service)
            let highlight = PDFHighlightRecord(
                id: UUID(),
                sourceId: source.id,
                page: 1,
                rects: [PDFHighlightRect(page: 1, x: 1, y: 2, w: 3, h: 4)],
                quote: "Undo must restore this link",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            try service.savePDFHighlight(highlight)
            try service.saveStreamDocument(streamId: source.streamId, markdown: "The link is temporarily gone.")

            XCTAssertEqual(try service.loadPDFHighlights(sourceId: source.id), [highlight])
        }
    }

    func test_tickerPDFURLParserAcceptsExistingHighlightDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let highlightId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?highlight=\(highlightId.uuidString)&page=4")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertEqual(destination.highlightId, highlightId.uuidString)
        XCTAssertEqual(destination.page, 4)
        XCTAssertNil(destination.chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_tickerPDFURLParserAcceptsLegacyBareHighlightDestination() throws {
        let highlightId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(highlightId.uuidString)")
        )

        XCTAssertNil(destination.sourceId)
        XCTAssertEqual(destination.highlightId, highlightId.uuidString)
        XCTAssertNil(destination.page)
        XCTAssertNil(destination.chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_pdfHighlightAnnotationTagAcceptsOnlyTickerHighlightUUIDs() throws {
        let highlightId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        XCTAssertEqual(
            PDFHighlightAnnotationTag.highlightId(
                from: PDFHighlightAnnotationTag.contents(for: highlightId)
            ),
            highlightId
        )
        XCTAssertNil(PDFHighlightAnnotationTag.highlightId(from: nil))
        XCTAssertNil(PDFHighlightAnnotationTag.highlightId(from: "citation-flash"))
        XCTAssertNil(PDFHighlightAnnotationTag.highlightId(from: "\(PDFHighlightAnnotationTag.prefix)not-a-uuid"))
    }

    func test_pdfHighlightClickTrackerRejectsDragEvenWhenMouseReturnsToStart() {
        var click = PDFHighlightClickTracker(mouseDownLocation: .zero)
        click.observe(CGPoint(x: 3, y: 2))
        XCTAssertFalse(click.exceededSlop)

        var drag = PDFHighlightClickTracker(mouseDownLocation: .zero)
        drag.observe(CGPoint(x: 10, y: 0))
        drag.observe(.zero)
        XCTAssertTrue(drag.exceededSlop)
    }

    func test_tickerPDFURLParserAcceptsCitationChunkDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?page=12&chunk=\(chunkId.uuidString)")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertNil(destination.highlightId)
        XCTAssertEqual(destination.page, 12)
        XCTAssertEqual(destination.chunkId, chunkId)
        XCTAssertNil(destination.quote)
    }

    func test_tickerPDFURLParserAcceptsCitationQuoteDestination() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))

        let destination = try XCTUnwrap(
            TickerPDFURLParser.parse("ticker-pdf://\(sourceId.uuidString)?page=12&chunk=\(chunkId.uuidString)&q=quoted%20evidence%20%26%20support")
        )

        XCTAssertEqual(destination.sourceId, sourceId)
        XCTAssertNil(destination.highlightId)
        XCTAssertEqual(destination.page, 12)
        XCTAssertEqual(destination.chunkId, chunkId)
        XCTAssertEqual(destination.quote, "quoted evidence & support")
    }

    func test_openPDFDestinationFailureMessagesArePlainLanguage() throws {
        XCTAssertEqual(
            OpenPDFDestinationFailure.missingSource.userMessage,
            "This link points to a source that's no longer in this stream."
        )
        XCTAssertEqual(
            OpenPDFDestinationFailure.damagedLink.userMessage,
            "This link is damaged and can't be opened."
        )
        XCTAssertEqual(
            OpenPDFDestinationFailure.wrongStream.userMessage,
            "This link points to a source in another stream."
        )
    }

    func test_pdfPaneOpeningLayoutGrowsLeftwardKeepingEditorSizeAndRightEdge() throws {
        // Accordion, pane on the LEFT: the window grows leftward by the pane
        // width — the right edge (the editor) and the editor's 800pt share
        // stay exactly where they were.
        let layout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 800, y: 120, width: 800, height: 700),
            visibleFrame: CGRect(x: 0, y: 25, width: 1600, height: 875),
            isNativeFullscreen: false
        )

        XCTAssertEqual(layout.targetWindowFrame, CGRect(x: 0, y: 120, width: 1600, height: 700))
        XCTAssertEqual(layout.paneWidth, 800)
        XCTAssertEqual(layout.targetWindowFrame.width - layout.paneWidth, 800) // editor unchanged
        XCTAssertEqual(layout.targetWindowFrame.maxX, 1600) // right edge fixed
        XCTAssertTrue(layout.shouldResizeWindow)
    }

    func test_pdfPaneOpeningLayoutSlidesRightOnlyWhenLeftEdgeClips() throws {
        // Not enough room to the left: the window slides right just enough to
        // fit the pane — translating the editor, never resizing it — and
        // height and vertical position stay untouched.
        let layout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 100, y: -200, width: 900, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
            isNativeFullscreen: false
        )

        XCTAssertEqual(layout.targetWindowFrame, CGRect(x: 0, y: -200, width: 1440, height: 900))
        XCTAssertEqual(layout.paneWidth, 540)
        XCTAssertEqual(layout.targetWindowFrame.width - layout.paneWidth, 900) // editor unchanged
        XCTAssertTrue(layout.shouldResizeWindow)
    }

    func test_pdfPaneOpeningLayoutSkipsResizeForFullWidthOrFullscreenWindow() throws {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let fullWidthLayout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: -10, y: 120, width: 1500, height: 700),
            visibleFrame: visibleFrame,
            isNativeFullscreen: false
        )
        let fullscreenLayout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 220, y: 120, width: 900, height: 700),
            visibleFrame: visibleFrame,
            isNativeFullscreen: true
        )

        XCTAssertEqual(fullWidthLayout.targetWindowFrame, CGRect(x: -10, y: 120, width: 1500, height: 700))
        XCTAssertEqual(fullWidthLayout.paneWidth, 750)
        XCTAssertFalse(fullWidthLayout.shouldResizeWindow)
        XCTAssertEqual(fullscreenLayout.targetWindowFrame, CGRect(x: 220, y: 120, width: 900, height: 700))
        XCTAssertEqual(fullscreenLayout.paneWidth, 450)
        XCTAssertFalse(fullscreenLayout.shouldResizeWindow)
    }

    func test_pdfPaneOpeningWidthIsInteriorAfterHostBasedMax() throws {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let layout = PDFPaneOpeningLayout.calculate(
            currentFrame: CGRect(x: 220, y: 120, width: 900, height: 700),
            visibleFrame: visibleFrame,
            isNativeFullscreen: false
        )
        let maxWidth = PDFPaneWidthPolicy.maxAllowedPDFPaneWidth(hostWidth: visibleFrame.width)

        XCTAssertEqual(layout.paneWidth, 540)
        XCTAssertGreaterThan(layout.paneWidth, PDFPaneWidthPolicy.minimumPDFPaneWidth)
        XCTAssertLessThan(layout.paneWidth, maxWidth)
    }

    func test_pdfPaneClampAllowsBothDirectionsForStandardHost() throws {
        let hostWidth: CGFloat = 1440
        let openingWidth = floor(hostWidth * 0.5)

        let smaller = PDFPaneWidthPolicy.clampPDFPaneWidth(openingWidth - 100, hostWidth: hostWidth)
        let larger = PDFPaneWidthPolicy.clampPDFPaneWidth(openingWidth + 100, hostWidth: hostWidth)

        XCTAssertLessThan(smaller, openingWidth)
        XCTAssertGreaterThan(larger, openingWidth)
        XCTAssertEqual(PDFPaneWidthPolicy.maxAllowedPDFPaneWidth(hostWidth: hostWidth), 1040)
    }

    func test_pdfPaneClampHandlesDegenerateSmallHosts() throws {
        XCTAssertEqual(PDFPaneWidthPolicy.maxAllowedPDFPaneWidth(hostWidth: 500), 320)
        XCTAssertEqual(PDFPaneWidthPolicy.clampPDFPaneWidth(900, hostWidth: 500), 320)

        XCTAssertEqual(PDFPaneWidthPolicy.maxAllowedPDFPaneWidth(hostWidth: 260), 260)
        XCTAssertEqual(PDFPaneWidthPolicy.clampPDFPaneWidth(900, hostWidth: 260), 260)
        XCTAssertEqual(PDFPaneWidthPolicy.clampPDFPaneWidth(20, hostWidth: 260), 260)
    }

    func test_pdfFindNavigationWrapsNextAndPrevious() throws {
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: nil, matchCount: 3), 0)
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: 0, matchCount: 3), 1)
        XCTAssertEqual(PDFFindNavigation.nextIndex(currentIndex: 2, matchCount: 3), 0)

        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: nil, matchCount: 3), 2)
        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: 2, matchCount: 3), 1)
        XCTAssertEqual(PDFFindNavigation.previousIndex(currentIndex: 0, matchCount: 3), 2)

        XCTAssertNil(PDFFindNavigation.nextIndex(currentIndex: nil, matchCount: 0))
        XCTAssertNil(PDFFindNavigation.previousIndex(currentIndex: nil, matchCount: 0))
    }

    func test_pdfDocumentFindReturnsCaseInsensitiveOrderedSelections() throws {
        let document = try makePDFDocument(pages: [
            "First needle is on the opening page.",
            "Second page carries NEEDLE again.",
            "No match here."
        ])

        let results = PDFDocumentFind.matches(in: document, query: "needle")

        XCTAssertFalse(results.isCapped)
        XCTAssertEqual(results.selections.count, 2)
        XCTAssertEqual(results.selections.compactMap { $0.pages.first.map { document.index(for: $0) } }, [0, 1])
        XCTAssertEqual(
            results.selections.compactMap { $0.string?.lowercased() },
            ["needle", "needle"]
        )
    }

    func test_pdfCitationNavigatorNormalizesQuoteText() throws {
        XCTAssertEqual(
            PDFCitationNavigator.normalizeQuote("Reader\u{2019}s \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines"),
            "reader's \"quoted\" text across lines"
        )
    }

    func test_pdfCitationNavigatorRecoversOriginalChunkSpanFromNormalizedQuote() throws {
        let chunkText = "Before reader's \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines after."
        let span = PDFCitationNavigator.verifiedOriginalSpan(
            in: chunkText,
            quote: "reader\u{2019}s \"quoted\"   text across lines"
        )

        XCTAssertEqual(span, "reader's \u{201C}quoted\u{201D}\ntext\u{00AD} across   lines")
    }

    func test_pdfCitationNavigatorUsesFirstGenericPhraseInChunk() throws {
        let chunkText = "First CHECK for stack underflow here. Later check for stack underflow there."
        let span = PDFCitationNavigator.verifiedOriginalSpan(
            in: chunkText,
            quote: "check for stack underflow"
        )

        XCTAssertEqual(span, "CHECK for stack underflow")
    }

    func test_pdfCitationNavigatorReturnsNilWhenQuoteIsAbsentFromChunk() throws {
        XCTAssertNil(
            PDFCitationNavigator.verifiedOriginalSpan(
                in: "Chunk text contains unrelated evidence.",
                quote: "absent quoted evidence"
            )
        )
    }

    func test_pdfCitationFallbackAffordanceOnlyShowsForCitationChunkFallback() throws {
        XCTAssertTrue(PDFCitationFallbackAffordance.shouldShow(chunkPresent: true, matchFound: false))
        XCTAssertFalse(PDFCitationFallbackAffordance.shouldShow(chunkPresent: true, matchFound: true))
        XCTAssertFalse(PDFCitationFallbackAffordance.shouldShow(chunkPresent: false, matchFound: false))
    }

    func test_pdfCitationNavigatorSelectsVerifiedQuoteOnExtractedPage() throws {
        let document = try makePDFDocument(pages: [
            "First page has only setup text.",
            "Second page says stack cells remain available for verified citation flashes.",
            "Third page has unrelated text."
        ])
        let chunkText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: chunkText,
            pageStart: 1,
            pageEnd: 3
        )

        let quote = "stack cells remain available for verified citation flashes"
        let match = try XCTUnwrap(PDFCitationNavigator.match(in: document, chunk: chunk, quote: quote))

        XCTAssertEqual(document.index(for: match.page), 1)
        XCTAssertFalse(match.bounds.isEmpty)
        XCTAssertTrue(PDFCitationNavigator.normalizeQuote(match.selection.string ?? "").contains(quote))
    }

    func test_pdfCitationNavigatorReturnsNilWhenVerifiedSpanIsAbsentFromPageText() throws {
        let document = try makePDFDocument(pages: [
            "First page text.",
            "Second page text."
        ])
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: "The stored chunk has absent quoted evidence that the page text does not expose.",
            pageStart: 2,
            pageEnd: 2
        )

        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: "absent quoted evidence"))
    }

    func test_pdfCitationNavigatorFallsBackToPageWhenQuoteIsAbsentOrMissed() throws {
        let document = try makePDFDocument(pages: [
            "First page text.",
            "Second page text."
        ])
        let chunk = SourceChunk(
            sourceId: UUID(),
            seq: 0,
            text: "This absent sentence is long enough to become the citation search needle.",
            pageStart: 2,
            pageEnd: 2
        )

        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: nil))
        XCTAssertNil(PDFCitationNavigator.match(in: document, chunk: chunk, quote: "absent quoted evidence"))
        XCTAssertEqual(PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: nil), 2)
        XCTAssertEqual(PDFCitationNavigator.fallbackPage(for: chunk, requestedPage: 1), 1)
    }

    func test_sourceShortTitleUsesAnnaArchiveFirstFilenameSegment() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "Thinking Forth -- Leo Brodie -- Anna's Archive.pdf"
            ),
            "Thinking Forth"
        )
    }

    func test_sourceShortTitleShedsTrailingParentheticalWhenLong() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "Forth Programmer's Handbook (3rd Edition) -- Edward K_ Conklin … -- Anna's Archive.pdf"
            ),
            "Forth Programmer's Handbook"
        )
    }

    func test_sourceShortTitleShedsSubtitleThenEndTruncatesAtWordBoundary() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "Structure and Interpretation of Computer Programs: Second Edition.pdf"
            ),
            "Structure and Interpretation of…"
        )
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "A Very Long Title Without Any Structural Separators To Shed Gracefully.pdf"
            ),
            "A Very Long Title Without Any…"
        )
    }

    func test_sourceShortTitleUsesPlainFilenameStem() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(displayName: "report.pdf"),
            "report"
        )
    }

    func test_sourceShortTitlePrefersSaneMetadataTitle() throws {
        XCTAssertEqual(
            SourceShortTitle.derive(
                displayName: "123456789.pdf",
                metadataTitle: "Clean Metadata Title"
            ),
            "Clean Metadata Title"
        )
    }

    func test_documentAICitationPayloadBuildsFromRetrievedSourceContext() throws {
        let firstSourceId = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let secondSourceId = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let firstChunkId = try XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let secondChunkId = try XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let context = SourceContext(
            text: "[1] abcdefghijklmnopqrstuvwxyzABCDE.pdf, p.12:\nAlpha\n\n[2] Guide.md, p.2:\nBeta",
            chunks: [
                RetrievedChunk(
                    id: firstChunkId,
                    sourceId: firstSourceId,
                    sourceName: "abcdefghijklmnopqrstuvwxyzABCDE.pdf",
                    seq: 0,
                    text: "Alpha",
                    pageStart: 12,
                    pageEnd: 12,
                    sectionPath: nil,
                    score: -10
                ),
                RetrievedChunk(
                    id: secondChunkId,
                    sourceId: secondSourceId,
                    sourceName: "Guide.md",
                    seq: 1,
                    text: "Beta",
                    pageStart: 2,
                    pageEnd: 3,
                    sectionPath: nil,
                    score: -8
                )
            ],
            mode: .retrieved
        )

        let payload = try XCTUnwrap(DocumentAICitationManifest.bridgePayload(from: context))

        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0]["n"] as? Int, 1)
        XCTAssertEqual(payload[0]["chunkId"] as? String, firstChunkId.uuidString)
        XCTAssertEqual(payload[0]["sourceId"] as? String, firstSourceId.uuidString)
        XCTAssertEqual(payload[0]["page"] as? Int, 12)
        XCTAssertEqual(payload[0]["shortTitle"] as? String, "abcdefghijklmnopqrstuvwxyzABCDE")
        XCTAssertEqual(payload[1]["n"] as? Int, 2)
        XCTAssertEqual(payload[1]["chunkId"] as? String, secondChunkId.uuidString)
        XCTAssertEqual(payload[1]["sourceId"] as? String, secondSourceId.uuidString)
        XCTAssertEqual(payload[1]["page"] as? Int, 2)
        XCTAssertEqual(payload[1]["shortTitle"] as? String, "Guide")
    }

    func test_citationMarkerSwapRendersPanelLabelAndMarkdownLinkFromSameManifest() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let manifest = [
            DocumentAICitationManifestEntry(
                n: 1,
                chunkId: chunkId,
                sourceId: sourceId,
                page: 4,
                shortTitle: "Manual [draft]"
            )
        ]
        let text = #"Use the stack carefully.【1|"stack words"】"#

        XCTAssertEqual(
            CitationMarkerSwap.swap(text, manifest: manifest, mode: .plainLabel),
            "Use the stack carefully. (Manual [draft] p.4)"
        )
        XCTAssertEqual(
            CitationMarkerSwap.swap(text, manifest: manifest, mode: .markdownLink),
            "Use the stack carefully. [Manual \\[draft\\] p.4](ticker-pdf://11111111-1111-1111-1111-111111111111?page=4&chunk=22222222-2222-2222-2222-222222222222&q=stack%20words)"
        )
    }

    func test_citationMarkerSwapToleratesProviderClosingBraceTypo() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let chunkId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let secondChunkId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let manifest = [
            DocumentAICitationManifestEntry(
                n: 1,
                chunkId: chunkId,
                sourceId: sourceId,
                page: 165,
                shortTitle: "Manual"
            ),
            DocumentAICitationManifestEntry(
                n: 2,
                chunkId: secondChunkId,
                sourceId: sourceId,
                page: 166,
                shortTitle: "Manual"
            )
        ]
        let text = #"Read this.【1|"The word UNUSED places on the stack"}"#

        XCTAssertEqual(
            CitationMarkerSwap.swap(text, manifest: manifest, mode: .markdownLink),
            "Read this. [Manual p.165](ticker-pdf://11111111-1111-1111-1111-111111111111?page=165&chunk=22222222-2222-2222-2222-222222222222&q=The%20word%20UNUSED%20places%20on%20the%20stack)"
        )
        XCTAssertEqual(
            CitationMarkerSwap.swap(
                #"Read this.【1|"pushes {x} onto the stack"】"#,
                manifest: manifest,
                mode: .markdownLink
            ),
            "Read this. [Manual p.165](ticker-pdf://11111111-1111-1111-1111-111111111111?page=165&chunk=22222222-2222-2222-2222-222222222222&q=pushes%20%7Bx%7D%20onto%20the%20stack)"
        )
        XCTAssertEqual(
            CitationMarkerSwap.swap(
                #"First.【1|"alpha"} prose Second.【2|"beta"】"#,
                manifest: manifest,
                mode: .markdownLink
            ),
            "First. [Manual p.165](ticker-pdf://11111111-1111-1111-1111-111111111111?page=165&chunk=22222222-2222-2222-2222-222222222222&q=alpha) prose Second. [Manual p.166](ticker-pdf://11111111-1111-1111-1111-111111111111?page=166&chunk=33333333-3333-3333-3333-333333333333&q=beta)"
        )
    }

    func test_pdfSectionAIMarkdownBuildsLinkedSummaryAndQuotedQuestion() throws {
        let sourceId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let descriptor = PDFSectionDescriptor(
            streamId: UUID(),
            sourceId: sourceId,
            sourceName: "Manual.pdf",
            shortTitle: "Manual",
            sectionPath: "Part I > Storage [draft]",
            sectionTitle: "Storage [draft]",
            pageStart: 4,
            pageEnd: 6
        )

        XCTAssertEqual(
            PDFSectionAIMarkdown.fragment(
                action: .summarize,
                descriptor: descriptor,
                prompt: nil,
                response: " Summary body. "
            ),
            "### [Storage \\[draft\\]](ticker-pdf://11111111-1111-1111-1111-111111111111?page=4)\n\nSummary body."
        )
        XCTAssertEqual(
            PDFSectionAIMarkdown.fragment(
                action: .ask,
                descriptor: descriptor,
                prompt: "First line\nSecond line",
                response: "Answer."
            ),
            "### Asked of [Storage \\[draft\\]](ticker-pdf://11111111-1111-1111-1111-111111111111?page=4)\n\n> First line\n> Second line\n\nAnswer."
        )
    }

    @MainActor
    func test_pdfSectionAIAppendsCitedResponseWithAtomicReceipt() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Reading")
            try service.saveStream(stream)
            let source = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [(0, "Opening section text supports the answer.", 4, 4, "Part I > Storage")]
            )
            let retrieval = RetrievalService(persistence: service)
            let registry = AIOperationRegistry()
            let recorder = BridgeMessageRecorder()
            let handler = AIMessageHandler(
                persistence: service,
                retrievalService: retrieval,
                aiOperations: registry,
                sendToWeb: { recorder.send($0) },
                routeDocumentAI: { _, _, routedImages, routedStreamId, _, context, systemPrompt, onChunk, onComplete, _, onModelSelected in
                    XCTAssertTrue(routedImages.isEmpty)
                    XCTAssertNil(routedStreamId)
                    XCTAssertEqual(context?.chunks.map(\.sourceId), [source.id])
                    XCTAssertEqual(systemPrompt, Prompts.pdfSectionSummary)
                    onModelSelected?("provider/model")
                    onChunk(#"Storage is supported.【1|"Opening section text supports"】"#)
                    onComplete(context)
                }
            )

            await handler.handle(BridgeMessage(type: "runPdfSectionAI", payload: [
                "action": AnyCodable("summarize"),
                "streamId": AnyCodable(stream.id.uuidString),
                "sourceId": AnyCodable(source.id.uuidString),
                "page": AnyCodable(4)
            ]))

            try await waitUntil {
                registry.operations.values.first?.state == .succeeded
            }

            let requestId = try XCTUnwrap(registry.operations.keys.first)
            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            let exchange = try XCTUnwrap(service.loadExchange(requestId: requestId))
            XCTAssertTrue(document.markdown.contains("### [Storage](ticker-pdf://\(source.id.uuidString)?page=4)"))
            XCTAssertTrue(document.markdown.contains("[Manual p.4](ticker-pdf://\(source.id.uuidString)?page=4&chunk="))
            XCTAssertEqual(exchange.verb, "summarize")
            XCTAssertTrue(exchange.responseRaw.contains("【1"))

            // The receipt is kept as a pending append rather than as a global span:
            // its coordinates are offsets into the fragment, and turning those into
            // document positions needs an editor. It stays until one converts it.
            XCTAssertTrue(try service.loadSpans(streamId: stream.id).isEmpty)
            let pending = try service.loadPendingAppends(streamId: stream.id)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending[0].revision, document.revision)
            let receiptData = try XCTUnwrap(pending[0].rawSpansJSON.data(using: .utf8))
            let receiptSpans = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptData) as? [[String: Any]])
            XCTAssertEqual(receiptSpans.first?["requestId"] as? String, requestId)

            let append = try XCTUnwrap(recorder.messages(ofType: "streamDocumentAppended").first)
            XCTAssertEqual(append.payload?["source"]?.value as? String, "pdfSectionAI")
            XCTAssertEqual(append.payload?["revision"]?.intValue, 1)
        }
    }

    @MainActor
    func test_cancelledPDFSectionAIDoesNotAppendLateCompletion() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Reading")
            try service.saveStream(stream)
            let source = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Manual.pdf",
                extractedText: largeExtractedText(),
                chunks: [(0, "Opening section text.", 4, 4, "Part I > Storage")]
            )
            let registry = AIOperationRegistry()
            let provider = SlowDocumentAIProvider()
            let handler = AIMessageHandler(
                persistence: service,
                retrievalService: RetrievalService(persistence: service),
                aiOperations: registry,
                sendToWeb: { _ in },
                routeDocumentAI: { _, _, _, _, _, context, systemPrompt, onChunk, onComplete, _, _ in
                    await provider.stream(
                        systemPrompt: systemPrompt,
                        onChunk: onChunk,
                        onComplete: { _ in onComplete(context) }
                    )
                }
            )

            await handler.handle(BridgeMessage(type: "runPdfSectionAI", payload: [
                "action": AnyCodable("summarize"),
                "streamId": AnyCodable(stream.id.uuidString),
                "sourceId": AnyCodable(source.id.uuidString),
                "page": AnyCodable(4)
            ]))
            try await waitUntil {
                registry.operations.values.first?.state == .generating
            }
            let requestId = try XCTUnwrap(registry.operations.keys.first)

            await handler.handle(BridgeMessage(type: "cancelAIOperation", payload: [
                "requestId": AnyCodable(requestId)
            ]))
            try await waitUntil { await provider.cancelled() }

            XCTAssertEqual(registry.operations[requestId]?.state, .canceled)
            XCTAssertNil(try service.loadStreamDocument(streamId: stream.id))
            XCTAssertNil(try service.loadExchange(requestId: requestId))
        }
    }

    @MainActor
    func test_pdfSectionAIRejectsOversizedQuestionBeforeRouting() async {
        let registry = AIOperationRegistry()
        var didRoute = false
        let handler = AIMessageHandler(
            aiOperations: registry,
            sendToWeb: { _ in },
            routeDocumentAI: { _, _, _, _, _, _, _, _, _, _, _ in
                didRoute = true
            }
        )

        await handler.handle(BridgeMessage(type: "runPdfSectionAI", payload: [
            "action": AnyCodable("ask"),
            "streamId": AnyCodable(UUID().uuidString),
            "sourceId": AnyCodable(UUID().uuidString),
            "page": AnyCodable(1),
            "prompt": AnyCodable(String(repeating: "x", count: (PDFSectionAIAction.maxPromptTokens + 1) * 4))
        ]))

        XCTAssertFalse(didRoute)
        XCTAssertEqual(registry.operations.values.first?.state, .failed)
        XCTAssertEqual(
            registry.operations.values.first?.message,
            "That section question is too long. Shorten it and try again."
        )
    }

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

    func test_saveStreamDocumentWithCurrentRevisionIncrementsRevision() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Revision Save")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(initialDocument.revision, 0)

            let firstRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "First save",
                baseRevision: initialDocument.revision
            )
            XCTAssertEqual(firstRevision, 1)

            let firstDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(firstDocument.markdown, "First save")
            XCTAssertEqual(firstDocument.revision, 1)

            let secondRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Second save",
                baseRevision: firstDocument.revision
            )
            XCTAssertEqual(secondRevision, 2)

            let secondDocument = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(secondDocument.markdown, "Second save")
            XCTAssertEqual(secondDocument.revision, 2)
        }
    }

    func test_saveCanonicalStreamDocumentIsAtomicAndRevisionChecked() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Canonical save")
            try service.saveStream(stream)
            let initial = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let firstJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"First"}]}]}"#

            let revision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: firstJSON,
                docFormatVersion: 1,
                markdown: "First",
                baseRevision: initial.revision,
                spans: []
            )

            let first = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(first.docJSON, firstJSON)
            XCTAssertEqual(first.docFormatVersion, 1)
            XCTAssertEqual(first.markdown, "First")
            XCTAssertEqual(first.revision, revision)
            let payload = StreamCodec.encodeStream(stream, document: first)
            let wireDocument = try XCTUnwrap(payload["document"] as? [String: Any])
            XCTAssertEqual(wireDocument["docJSON"] as? String, firstJSON)
            XCTAssertEqual(wireDocument["docFormatVersion"] as? Int, 1)

            let staleJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Stale"}]}]}"#
            do {
                _ = try service.saveStreamDocument(
                    streamId: stream.id,
                    docJSON: staleJSON,
                    docFormatVersion: 1,
                    markdown: "Stale",
                    baseRevision: initial.revision,
                    spans: []
                )
                XCTFail("Expected stale canonical save to throw")
            } catch let conflict as StreamDocumentRevisionConflict {
                XCTAssertEqual(conflict.docJSON, firstJSON)
                XCTAssertEqual(conflict.docFormatVersion, 1)
                XCTAssertEqual(conflict.markdown, "First")
                XCTAssertEqual(conflict.revision, revision)
            }

            let after = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(after.docJSON, firstJSON)
            XCTAssertEqual(after.docFormatVersion, 1)
            XCTAssertEqual(after.markdown, "First")
            XCTAssertEqual(after.revision, revision)
        }
    }

    func test_editorSnapshotCarriesAppendInboxInDatabaseOrder() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Inbox snapshot")
            let other = Stream(title: "Other inbox")
            try service.saveStream(stream)
            try service.saveStream(other)
            let thread = StreamThread(
                streamId: stream.id,
                anchorText: "First",
                anchorStart: 1,
                anchorEnd: 6
            )
            try service.createStreamThread(thread)

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox
                            (append_id, stream_id, fragment, raw_spans_json, created_at)
                        VALUES
                            ('append-1', ?, 'First', '[]', 1000),
                            ('append-other', ?, 'Other', '[]', 1001),
                            ('append-3', ?, 'Third', '[{"spanId":"span-3"}]', 1002)
                    """,
                    arguments: [stream.id.uuidString, other.id.uuidString, stream.id.uuidString]
                )
            }

            let snapshot = try service.loadEditorSnapshot(streamId: stream.id)
            XCTAssertEqual(snapshot.appendInbox.map(\.seq), [1, 3])
            XCTAssertEqual(snapshot.appendInbox.map(\.appendId), ["append-1", "append-3"])
            XCTAssertEqual(snapshot.appendInbox.map(\.fragment), ["First", "Third"])
            XCTAssertEqual(snapshot.appendInbox.last?.rawSpansJSON, #"[{"spanId":"span-3"}]"#)
            XCTAssertEqual(snapshot.appendInbox.last?.createdAt, Date(timeIntervalSince1970: 1002))
            XCTAssertEqual(snapshot.conversationAnchors.map(\.threadId), [thread.threadId])

            let wire = StreamCodec.encodeAppendInbox(snapshot.appendInbox)
            XCTAssertEqual(wire.map { $0["seq"]?.intValue }, [1, 3])
            XCTAssertEqual(wire.map { $0["appendId"]?.value as? String }, ["append-1", "append-3"])
            XCTAssertNoThrow(try JSONEncoder().encode(BridgeMessage(
                type: "streamLoaded",
                payload: ["appendInbox": AnyCodable(wire)]
            )))
        }
    }

    func test_canonicalSaveAtomicallyConsumesOnlyTheInboxRowsItReduced() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Inbox consume")
            let other = Stream(title: "Other inbox")
            try service.saveStream(stream)
            try service.saveStream(other)
            let baseJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Base"}]}]}"#
            let baseRevision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: baseJSON,
                docFormatVersion: 1,
                markdown: "Base",
                baseRevision: 0,
                spans: []
            )

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let consumedSeq = try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES
                            ('append-other', ?, 'Other', 999),
                            ('append-consumed', ?, 'Consumed', 1000)
                    """,
                    arguments: [other.id.uuidString, stream.id.uuidString]
                )
                return Int(db.lastInsertedRowID)
            }
            XCTAssertEqual(
                try service.loadEditorSnapshot(streamId: stream.id).appendInbox.map(\.seq),
                [consumedSeq]
            )

            // This arrives after the editor's snapshot. Its watermark must not
            // consume this later row or the older row belonging to another stream.
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES ('append-later', ?, 'Later', 1002)
                    """,
                    arguments: [stream.id.uuidString]
                )
            }

            let span = ProvenanceSpan(
                spanId: "span-consumed",
                streamId: stream.id,
                start: 7,
                end: 15,
                origin: "capture",
                textHash: FNV1a.hash("Consumed"),
                createdAt: Date(timeIntervalSince1970: 1000)
            )
            let combinedJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Base"}]},{"type":"paragraph","content":[{"type":"text","text":"Consumed"}]}]}"#
            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: combinedJSON,
                docFormatVersion: 1,
                markdown: "Base\n\nConsumed",
                baseRevision: baseRevision,
                spans: [span],
                consumedInboxThrough: consumedSeq
            )

            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.docJSON, combinedJSON)
            XCTAssertEqual(
                try service.loadStreamDocument(streamId: stream.id)?.markdown,
                "Base\n\nConsumed\n\nLater"
            )
            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [span])
            let remaining = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT append_id FROM stream_append_inbox
                        WHERE consumed_at IS NULL
                        ORDER BY seq
                    """
                ).map { $0["append_id"] as String }
            }
            XCTAssertEqual(remaining, ["append-other", "append-later"])
        }
    }

    func test_foreignInboxWatermarkRollsBackTheWholeCanonicalSave() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Inbox rollback")
            let other = Stream(title: "Foreign inbox")
            try service.saveStream(stream)
            try service.saveStream(other)
            let originalJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Original"}]}]}"#
            let originalSpan = ProvenanceSpan(
                spanId: "span-original",
                streamId: stream.id,
                start: 1,
                end: 9,
                origin: "capture",
                textHash: FNV1a.hash("Original"),
                createdAt: Date(timeIntervalSince1970: 1000)
            )
            let revision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: originalJSON,
                docFormatVersion: 1,
                markdown: "Original",
                baseRevision: 0,
                spans: [originalSpan]
            )

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let foreignSeq = try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES
                            ('append-real', ?, 'Queued', 1001),
                            ('append-foreign', ?, 'Foreign', 1002)
                    """,
                    arguments: [stream.id.uuidString, other.id.uuidString]
                )
                return Int(db.lastInsertedRowID)
            }

            XCTAssertThrowsError(try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Wrong"}]}]}"#,
                docFormatVersion: 1,
                markdown: "Wrong",
                baseRevision: revision,
                spans: [],
                consumedInboxThrough: foreignSeq
            ))

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.docJSON, originalJSON)
            XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [originalSpan])
            XCTAssertEqual(
                try dbQueue.read { db in
                    try String.fetchAll(
                        db,
                        sql: "SELECT append_id FROM stream_append_inbox ORDER BY seq"
                    )
                },
                ["append-real", "append-foreign"]
            )
        }
    }

    func test_staleCanonicalSaveCannotConsumeInboxRows() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, _ in
            let stream = Stream(title: "Stale inbox save")
            try service.saveStream(stream)
            let json = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            let staleRevision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: json,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: 0,
                spans: []
            )

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let seq = try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO stream_append_inbox (append_id, stream_id, fragment, created_at)
                        VALUES ('append-stale', ?, 'Queued', 1000)
                    """,
                    arguments: [stream.id.uuidString]
                )
                return Int(db.lastInsertedRowID)
            }
            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: json,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: staleRevision,
                spans: []
            )

            do {
                _ = try service.saveStreamDocument(
                    streamId: stream.id,
                    docJSON: json,
                    docFormatVersion: 1,
                    markdown: "",
                    baseRevision: staleRevision,
                    spans: [],
                    consumedInboxThrough: seq
                )
                XCTFail("Expected stale inbox save to throw")
            } catch let conflict as StreamDocumentRevisionConflict {
                XCTAssertEqual(conflict.appendInbox.map(\.seq), [seq])
                XCTAssertEqual(conflict.appendInbox.first?.fragment, "Queued")
            }
            XCTAssertEqual(
                try dbQueue.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_append_inbox")
                },
                1
            )
        }
    }

    func test_enqueueStreamAppendUpdatesOnlyTheProjectionAndReturnsTheFullInbox() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Canonical inbox")
            try service.saveStream(stream)
            let baseJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Base"}]}]}"#
            let revision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: baseJSON,
                docFormatVersion: 1,
                markdown: "Base",
                baseRevision: 0,
                spans: []
            )
            let fragment = "**Captured.**"
            let span = ProvenanceSpan(
                spanId: "queued-span",
                streamId: stream.id,
                start: 0,
                end: UTF16Offsets.utf16Length(fragment),
                origin: "capture",
                textHash: FNV1a.hash(fragment),
                createdAt: Date(timeIntervalSince1970: 1000)
            )

            let first = try service.enqueueStreamAppend(
                appendId: "append-first",
                streamId: stream.id,
                fragment: fragment,
                spans: [span]
            )
            let second = try service.enqueueStreamAppend(
                appendId: "append-second",
                streamId: stream.id,
                fragment: "Second.",
                spans: []
            )

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.docJSON, baseJSON)
            XCTAssertEqual(document.docFormatVersion, 1)
            XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(document.markdown, "Base\n\n**Captured.**\n\nSecond.")
            XCTAssertEqual(first.map(\.appendId), ["append-first"])
            XCTAssertEqual(second.map(\.appendId), ["append-first", "append-second"])
            XCTAssertEqual(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.map(\.appendId), second.map(\.appendId))
            XCTAssertTrue(try service.loadPendingAppends(streamId: stream.id).isEmpty)

            let rawData = try XCTUnwrap(first[0].rawSpansJSON.data(using: .utf8))
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: rawData) as? [[String: Any]])
            XCTAssertEqual(raw.first?["spanId"] as? String, "queued-span")
            XCTAssertEqual(raw.first?["start"] as? Int, 0)
            XCTAssertEqual(raw.first?["end"] as? Int, UTF16Offsets.utf16Length(fragment))
        }
    }

    func test_enqueueStreamAppendIsIdempotentOnlyForIdenticalContent() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Idempotent inbox")
            let other = Stream(title: "Other inbox")
            try service.saveStream(stream)
            try service.saveStream(other)
            let baseJSON = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            let baseRevision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: baseJSON,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: 0,
                spans: []
            )
            let span = ProvenanceSpan(
                spanId: "same-span",
                streamId: stream.id,
                start: 0,
                end: 8,
                origin: "capture",
                textHash: FNV1a.hash("Captured"),
                createdAt: Date(timeIntervalSince1970: 1000)
            )

            let first = try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: stream.id,
                fragment: "Captured",
                spans: [span]
            )
            let retry = try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: stream.id,
                fragment: "Captured",
                spans: [span]
            )

            XCTAssertEqual(retry.map(\.seq), first.map(\.seq))
            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "Captured")
            XCTAssertEqual(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.count, 1)

            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: stream.id,
                fragment: "Different",
                spans: [span]
            ))
            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: other.id,
                fragment: "Captured",
                spans: [span]
            ))
            let changedSpan = ProvenanceSpan(
                spanId: span.spanId,
                streamId: span.streamId,
                start: span.start,
                end: span.end,
                origin: span.origin,
                textHash: FNV1a.hash("Different"),
                createdAt: span.createdAt
            )
            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: stream.id,
                fragment: "Captured",
                spans: [changedSpan]
            ))
            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "Captured")
            XCTAssertEqual(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.count, 1)

            let capturedJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Captured"}]}]}"#
            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: capturedJSON,
                docFormatVersion: 1,
                markdown: "Captured",
                baseRevision: baseRevision,
                spans: [span],
                consumedInboxThrough: first[0].seq
            )
            let lateRetry = try service.enqueueStreamAppend(
                appendId: "same-operation",
                streamId: stream.id,
                fragment: "Captured",
                spans: [span]
            )
            XCTAssertTrue(lateRetry.isEmpty)
            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "Captured")
        }
    }

    func test_enqueueStreamAppendRollsBackProjectionAndRowWhenExchangeFails() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Atomic inbox")
            try service.saveStream(stream)
            let baseJSON = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Before"}]}]}"#
            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: baseJSON,
                docFormatVersion: 1,
                markdown: "Before",
                baseRevision: 0,
                spans: []
            )
            let exchange = AIExchange(
                requestId: "atomic-inbox",
                streamId: UUID(),
                verb: "develop",
                userInput: "Prompt",
                responseRaw: "Answer"
            )

            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "atomic-inbox",
                streamId: stream.id,
                fragment: "Answer",
                spans: [],
                exchange: exchange
            ))
            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "Before")
            XCTAssertTrue(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.isEmpty)
            XCTAssertNil(try service.loadExchange(requestId: "atomic-inbox"))
        }
    }

    func test_enqueueStreamAppendRefusesBlankOrUnconvertedDocuments() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Unconverted inbox")
            try service.saveStream(stream)
            _ = try service.loadOrCreateStreamDocument(streamId: stream.id)

            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "unconverted",
                streamId: stream.id,
                fragment: "Captured",
                spans: []
            ))

            let baseJSON = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: baseJSON,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: 0,
                spans: []
            )
            XCTAssertThrowsError(try service.enqueueStreamAppend(
                appendId: "blank",
                streamId: stream.id,
                fragment: " \n ",
                spans: []
            ))
            XCTAssertTrue(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.isEmpty)
        }
    }

    func test_externalAppendGateKeepsLegacyUntilCutoverAndQueuesAfterIt() throws {
        try withTempPersistenceService(usesAppendInbox: false) { service in
            let stream = Stream(title: "Legacy gate")
            try service.saveStream(stream)
            let result = try service.appendExternal(
                appendId: "legacy-operation",
                streamId: stream.id,
                fragment: "Legacy",
                spans: []
            )
            guard case .legacy = result else {
                return XCTFail("Expected legacy append before cutover")
            }
            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "Legacy")
            XCTAssertTrue(try service.loadEditorSnapshot(streamId: stream.id).appendInbox.isEmpty)
        }

        try withTempPersistenceService(usesAppendInbox: true) { service in
            let stream = Stream(title: "Canonical gate")
            try service.saveStream(stream)
            let result = try service.appendExternal(
                appendId: "canonical-operation",
                streamId: stream.id,
                fragment: "Queued",
                spans: []
            )
            guard case .inbox(let inbox) = result else {
                return XCTFail("Expected inbox append after cutover")
            }
            XCTAssertEqual(inbox.map(\.appendId), ["canonical-operation"])
            let second = try service.appendExternal(
                appendId: "canonical-operation-2",
                streamId: stream.id,
                fragment: "Second",
                spans: []
            )
            let message = StreamCodec.externalAppendMessage(
                streamId: stream.id,
                result: second,
                isNewStream: true,
                source: "quickPanel"
            )
            let wireInbox = try XCTUnwrap(
                message.payload?["appendInbox"]?.value as? [[String: AnyCodable]]
            )
            XCTAssertEqual(message.type, "streamAppendInboxChanged")
            XCTAssertEqual(message.payload?["isNewStream"]?.value as? Bool, true)
            XCTAssertEqual(message.payload?["source"]?.value as? String, "quickPanel")
            XCTAssertEqual(
                wireInbox.map { $0["appendId"]?.value as? String },
                ["canonical-operation", "canonical-operation-2"]
            )
            XCTAssertEqual(
                try service.loadStreamDocument(streamId: stream.id)?.docJSON,
                #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            )
            XCTAssertTrue(try service.loadPendingAppends(streamId: stream.id).isEmpty)
        }
    }

    func test_canonicalCutoverRefusesAnUnconvertedDocument() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, fileManager in
            let stream = Stream(title: "Still Markdown")
            try service.saveStream(stream)
            _ = try service.loadOrCreateStreamDocument(streamId: stream.id)

            XCTAssertThrowsError(try PersistenceService(
                databaseURL: dbURL,
                fileManager: fileManager,
                usesAppendInbox: true
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("conversion"))
            }
        }
    }

    func test_canonicalCutoverRefusesAStreamWithNoDocumentRow() throws {
        try withTempPersistenceServiceAndURL { service, dbURL, fileManager in
            try service.saveStream(Stream(title: "Missing document"))

            XCTAssertThrowsError(try PersistenceService(
                databaseURL: dbURL,
                fileManager: fileManager,
                usesAppendInbox: true
            ))
        }
    }

    func test_legacyWritersInvalidateCanonicalDocumentInsteadOfLeavingItStale() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Canonical invalidation")
            try service.saveStream(stream)
            let json = #"{"type":"doc","content":[{"type":"paragraph"}]}"#
            let firstRevision = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: json,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: 0,
                spans: []
            )

            let secondRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "CodeMirror edit",
                baseRevision: firstRevision
            )
            let afterLegacySave = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertNil(afterLegacySave.docJSON)
            XCTAssertNil(afterLegacySave.docFormatVersion)

            _ = try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: json,
                docFormatVersion: 1,
                markdown: "",
                baseRevision: secondRevision,
                spans: []
            )
            _ = try service.appendToStreamDocument(streamId: stream.id, fragment: "Capture")
            let afterAppend = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertNil(afterAppend.docJSON)
            XCTAssertNil(afterAppend.docFormatVersion)
        }
    }

    func test_saveCanonicalStreamDocumentRejectsUnknownFormatWithoutWriting() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Unknown canonical format")
            try service.saveStream(stream)

            XCTAssertThrowsError(try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: #"{"type":"doc","content":[]}"#,
                docFormatVersion: 2,
                markdown: "",
                baseRevision: 0,
                spans: []
            ))
            XCTAssertThrowsError(try service.saveStreamDocument(
                streamId: stream.id,
                docJSON: "{not json",
                docFormatVersion: 1,
                markdown: "",
                baseRevision: 0,
                spans: []
            ))

            let document = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertNil(document.docJSON)
            XCTAssertNil(document.docFormatVersion)
            XCTAssertEqual(document.revision, 0)
        }
    }

    func test_appendToStreamDocumentIncrementsRevision() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Append Revision")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            XCTAssertEqual(initialDocument.revision, 0)

            let firstAppend = try service.appendToStreamDocument(streamId: stream.id, fragment: "First append")
            XCTAssertEqual(firstAppend.revision, 1)

            let secondAppend = try service.appendToStreamDocument(streamId: stream.id, fragment: "Second append")
            XCTAssertEqual(secondAppend.revision, 2)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "First append\n\nSecond append")
            XCTAssertEqual(document.revision, 2)
        }
    }

    func test_appendToStreamDocumentKeepsFragmentRelativeSpansPending() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Append Span Offset")
            try service.saveStream(stream)
            try service.saveStreamDocument(streamId: stream.id, markdown: "a🙂")
            let span = ProvenanceSpan(
                spanId: "span-ai",
                streamId: stream.id,
                start: 0,
                end: UTF16Offsets.utf16Length("Hello"),
                origin: "ai",
                requestId: "request-1",
                textHash: FNV1a.hash("Hello"),
                createdAt: Date(timeIntervalSince1970: 2_020)
            )

            let result = try service.appendToStreamDocument(streamId: stream.id, fragment: "Hello", spans: [span])

            XCTAssertEqual(try service.loadStreamDocument(streamId: stream.id)?.markdown, "a🙂\n\nHello")
            // The offsets stay relative to the FRAGMENT. Shifting them by the
            // length of the existing Markdown — which is what the emoji tail in
            // this test used to exercise — produces a Markdown offset, and
            // provenance coordinates are ProseMirror document positions now. Only
            // an editor can convert them, so the append is kept verbatim instead.
            XCTAssertEqual(result.spans.count, 1)
            XCTAssertEqual(result.spans[0].start, 0)
            XCTAssertEqual(result.spans[0].end, 5)
            XCTAssertEqual(result.spans[0].textHash, FNV1a.hash("Hello"))
            XCTAssertTrue(try service.loadSpans(streamId: stream.id).isEmpty)

            let pending = try service.loadPendingAppends(streamId: stream.id)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending[0].revision, result.revision)
            XCTAssertEqual(pending[0].fragment, "Hello")
            let helloData = try XCTUnwrap(pending[0].rawSpansJSON.data(using: .utf8))
            let helloSpans = try XCTUnwrap(JSONSerialization.jsonObject(with: helloData) as? [[String: Any]])
            XCTAssertEqual(helloSpans.first?["start"] as? Int, 0)
        }
    }

    func test_appendToStreamDocumentRollsBackAnswerAndSpanWhenExchangeFails() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Atomic AI Append")
            try service.saveStream(stream)
            _ = try service.saveStreamDocument(streamId: stream.id, markdown: "Before")
            let span = ProvenanceSpan(
                streamId: stream.id,
                start: 0,
                end: UTF16Offsets.utf16Length("AI answer"),
                origin: "ai",
                requestId: "atomic-request",
                textHash: FNV1a.hash("AI answer")
            )
            let exchange = AIExchange(
                requestId: "atomic-request",
                streamId: UUID(),
                verb: "develop",
                userInput: "Prompt",
                sourceManifest: "[]",
                responseRaw: "AI answer"
            )

            XCTAssertThrowsError(try service.appendToStreamDocument(
                streamId: stream.id,
                fragment: "AI answer",
                spans: [span],
                exchange: exchange
            ))

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Before")
            XCTAssertEqual(document.revision, 1)
            XCTAssertTrue(try service.loadSpans(streamId: stream.id).isEmpty)
            XCTAssertNil(try service.loadExchange(requestId: "atomic-request"))
        }
    }

    @MainActor
    func test_aiOperationRegistryEmitsCorrelatedTransitionsAndStopsAtTerminalState() {
        let registry = AIOperationRegistry()
        var changes: [AIOperationRegistry.Operation] = []
        registry.onChange = { changes.append($0) }
        let streamId = UUID()

        let requestId = registry.begin(streamId: streamId, verb: "develop", origin: "quickPanel")
        registry.transition(requestId, to: .preparing)
        registry.transition(requestId, to: .generating)
        registry.transition(requestId, to: .generating)
        registry.transition(requestId, to: .saving)
        registry.transition(requestId, to: .succeeded)
        registry.transition(requestId, to: .failed, message: "late callback")

        XCTAssertEqual(changes.map(\.state), [.queued, .preparing, .generating, .saving, .succeeded])
        XCTAssertEqual(changes.last?.requestId, requestId)
        XCTAssertEqual(changes.last?.streamId, streamId)
        XCTAssertEqual(changes.last?.verb, "develop")
        XCTAssertEqual(changes.last?.origin, "quickPanel")
    }

    @MainActor
    func test_aiOperationRegistryCancelsAttachedTask() {
        let registry = AIOperationRegistry()
        let requestId = registry.begin(streamId: UUID(), verb: "develop", origin: "quickPanel")
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        registry.attach(task, to: requestId)

        registry.cancel(requestId)

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(registry.operations[requestId]?.state, .canceled)
    }

    @MainActor
    func test_quickPanelAIFragmentAppendSavesExchangeAndSpan() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Quick Panel AI")
            try service.saveStream(stream)
            let manager = QuickPanelManager()

            manager.appendQuickPanelAIFragment(
                streamId: stream.id,
                fragment: "AI answer",
                persistence: service,
                requestId: "quick-ai-request",
                model: "provider/model",
                prompt: "Summarize",
                documentMarkdown: "Captured context"
            )

            // Kept as a pending append: its offsets are into the fragment, and
            // turning those into document positions needs an editor.
            XCTAssertTrue(try service.loadSpans(streamId: stream.id).isEmpty)
            let spans = try service.loadPendingAppends(streamId: stream.id)
            XCTAssertEqual(spans.count, 1)
            XCTAssertEqual(spans[0].fragment, "AI answer")

            // Decoded rather than matched as a substring: Foundation escapes a
            // forward slash, so "provider/model" is never literally in the JSON.
            let rawSpanData = try XCTUnwrap(spans[0].rawSpansJSON.data(using: .utf8))
            let rawSpans = try XCTUnwrap(JSONSerialization.jsonObject(with: rawSpanData) as? [[String: Any]])
            XCTAssertEqual(rawSpans.count, 1)
            XCTAssertEqual(rawSpans[0]["requestId"] as? String, "quick-ai-request")
            XCTAssertEqual(rawSpans[0]["origin"] as? String, "ai")
            // The point of the row: offsets relative to the FRAGMENT, not shifted
            // into the document's Markdown.
            XCTAssertEqual(rawSpans[0]["start"] as? Int, 0)
            XCTAssertEqual(rawSpans[0]["end"] as? Int, UTF16Offsets.utf16Length("AI answer"))

            // The span's own metadata rides along, so an editor gets it back
            // unchanged when it converts the coordinates.
            let spanMetaData = try XCTUnwrap((rawSpans[0]["meta"] as? String)?.data(using: .utf8))
            let spanMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: spanMetaData) as? [String: String])
            XCTAssertEqual(spanMeta["model"], "provider/model")
            XCTAssertEqual(spanMeta["verb"], "develop")

            let exchange = try XCTUnwrap(service.loadExchange(requestId: "quick-ai-request"))
            XCTAssertEqual(exchange.streamId, stream.id)
            XCTAssertEqual(exchange.verb, "develop")
            XCTAssertEqual(exchange.userInput, "Selection:\nCaptured context\n\nPrompt:\nSummarize")
            XCTAssertEqual(exchange.responseRaw, "AI answer")
            XCTAssertEqual(exchange.model, "provider/model")
        }
    }

    @MainActor
    func test_saveConversationMessageKeepsAIReceiptWithMarkdownLinksAndExchange() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Kept AI")
            try service.saveStream(stream)
            let manager = QuickPanelManager(persistence: service)
            let savedMarkdown = "Answer [Manual p.4](ticker-pdf://source?page=4)"
            let rawResponse = "Answer 【1】"
            let manifest = #"[{"n":1,"shortTitle":"Manual"}]"#
            let turn = ConversationTurn(
                role: .assistant,
                content: "Answer (Manual p.4)",
                contextIncluded: false,
                saveContent: savedMarkdown,
                aiReceipt: QuickPanelAIReceipt(
                    streamId: stream.id,
                    requestId: "kept-panel-ai",
                    model: "provider/model",
                    userInput: "Selection:\n\nPrompt:\nQuestion",
                    sourceManifest: manifest,
                    responseRaw: rawResponse
                )
            )

            XCTAssertTrue(manager.saveConversationMessage(turn))

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, savedMarkdown)
            XCTAssertTrue(try service.loadSpans(streamId: stream.id).isEmpty)
            let spans = try service.loadPendingAppends(streamId: stream.id)
            XCTAssertEqual(spans.count, 1)
            let keptData = try XCTUnwrap(spans[0].rawSpansJSON.data(using: .utf8))
            let keptSpans = try XCTUnwrap(JSONSerialization.jsonObject(with: keptData) as? [[String: Any]])
            XCTAssertEqual(keptSpans.first?["origin"] as? String, "ai")
            XCTAssertEqual(keptSpans.first?["requestId"] as? String, "kept-panel-ai")
            let exchange = try XCTUnwrap(service.loadExchange(requestId: "kept-panel-ai"))
            XCTAssertEqual(exchange.sourceManifest, manifest)
            XCTAssertEqual(exchange.responseRaw, rawResponse)
            XCTAssertEqual(exchange.userInput, "Selection:\n\nPrompt:\nQuestion")
        }
    }

    /// The editor's opening snapshot has to describe ONE state.
    ///
    /// Read separately, an append landing between the reads hands the editor a
    /// document and a set of rows that never existed together — a row past the
    /// document's revision, or a fragment on the end with no row to explain it.
    /// Replaying is a proof about one consistent state, so either shape can only be
    /// refused, and every append's provenance is lost for nothing.
    func test_editorSnapshotIsInternallyConsistentUnderConcurrentAppends() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Snapshot")
            try service.saveStream(stream)
            _ = try service.saveStreamDocument(streamId: stream.id, markdown: "base", baseRevision: 0)

            // Appends running WHILE the snapshot is read, repeatedly, so an
            // interleaving actually gets a chance to happen rather than being
            // argued away.
            let done = expectation(description: "appends finished")
            DispatchQueue.global().async {
                for i in 0..<40 {
                    _ = try? service.appendToStreamDocument(streamId: stream.id, fragment: "fragment \(i)")
                }
                done.fulfill()
            }

            for _ in 0..<40 {
                let snapshot = try service.loadEditorSnapshot(streamId: stream.id)
                // No row may describe an append the document has not got yet.
                XCTAssertNil(snapshot.pendingAppends.first(where: { $0.revision > snapshot.document.revision }),
                             "a pending row ran ahead of the document it was read with")
                // And every row has to peel off the end of that same document,
                // newest first — which is exactly what the editor's replay does.
                var remaining = snapshot.document.markdown
                for row in snapshot.pendingAppends.sorted(by: { $0.revision > $1.revision }) {
                    let suffix = "\(row.separator)\(row.fragment)"
                    XCTAssertTrue(remaining.hasSuffix(suffix),
                                  "row \(row.revision) is not on the end of the document it was read with")
                    remaining = String(remaining.dropLast(suffix.count))
                }
            }

            wait(for: [done], timeout: 30)
        }
    }

    /// A conflict is another editor snapshot: its markdown, revision and pending
    /// rows have to describe the same instant or the editor can only refuse them.
    func test_revisionConflictIsInternallyConsistentUnderConcurrentAppends() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Conflict Snapshot")
            try service.saveStream(stream)
            _ = try service.saveStreamDocument(streamId: stream.id, markdown: "base", baseRevision: 0)

            let done = expectation(description: "appends finished")
            DispatchQueue.global().async {
                for i in 0..<40 {
                    _ = try? service.appendToStreamDocument(streamId: stream.id, fragment: "fragment \(i)")
                }
                done.fulfill()
            }

            for _ in 0..<40 {
                do {
                    _ = try service.saveStreamDocument(
                        streamId: stream.id,
                        markdown: "stale",
                        baseRevision: 0
                    )
                    XCTFail("Expected stale revision save to throw")
                } catch let conflict as StreamDocumentRevisionConflict {
                    XCTAssertNil(conflict.pendingAppends.first(where: { $0.revision > conflict.revision }),
                                 "a pending row ran ahead of the conflict document")
                    var remaining = conflict.markdown
                    for row in conflict.pendingAppends.sorted(by: { $0.revision > $1.revision }) {
                        let suffix = "\(row.separator)\(row.fragment)"
                        XCTAssertTrue(remaining.hasSuffix(suffix),
                                      "row \(row.revision) is not on the end of its conflict document")
                        remaining = String(remaining.dropLast(suffix.count))
                    }
                    XCTAssertEqual(remaining, "base")
                }
            }

            wait(for: [done], timeout: 30)
        }
    }

    func test_staleRevisionSaveDoesNotClobberInterleavedAppend() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Conflict Guard")
            try service.saveStream(stream)

            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let savedRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Editor draft",
                baseRevision: initialDocument.revision
            )
            XCTAssertEqual(savedRevision, 1)

            let append = try service.appendToStreamDocument(streamId: stream.id, fragment: "External append")
            XCTAssertEqual(append.revision, 2)

            do {
                _ = try service.saveStreamDocument(
                    streamId: stream.id,
                    markdown: "Editor stale overwrite",
                    baseRevision: savedRevision
                )
                XCTFail("Expected stale revision save to throw")
            } catch let conflict as StreamDocumentRevisionConflict {
                XCTAssertEqual(conflict.streamId, stream.id)
                XCTAssertEqual(conflict.revision, append.revision)
                XCTAssertEqual(conflict.markdown, "Editor draft\n\nExternal append")
            }

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: stream.id))
            XCTAssertEqual(document.markdown, "Editor draft\n\nExternal append")
            XCTAssertEqual(document.revision, append.revision)
        }
    }

    func test_saveStreamDocumentWithSpansRejectsStaleRevisionAndLeavesSpansUnchanged() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Span Conflict Guard")
            try service.saveStream(stream)
            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let originalSpan = ProvenanceSpan(
                spanId: "span-original",
                streamId: stream.id,
                start: 0,
                end: 5,
                origin: "ai",
                requestId: "request-1",
                textHash: FNV1a.hash("Hello"),
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
            let savedRevision = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Hello world",
                baseRevision: initialDocument.revision,
                spans: [originalSpan]
            )

            let append = try service.appendToStreamDocument(streamId: stream.id, fragment: "External append")
            let staleSpan = ProvenanceSpan(
                spanId: "span-stale",
                streamId: stream.id,
                start: 0,
                end: 5,
                origin: "ai",
                requestId: "request-2",
                textHash: FNV1a.hash("Stale"),
                createdAt: Date(timeIntervalSince1970: 2_001)
            )

            do {
                _ = try service.saveStreamDocument(
                    streamId: stream.id,
                    markdown: "Stale overwrite",
                    baseRevision: savedRevision,
                    spans: [staleSpan]
                )
                XCTFail("Expected stale revision save to throw")
            } catch let conflict as StreamDocumentRevisionConflict {
                XCTAssertEqual(conflict.streamId, stream.id)
                XCTAssertEqual(conflict.revision, append.revision)
                XCTAssertEqual(conflict.markdown, "Hello world\n\nExternal append")
                XCTAssertEqual(conflict.spans, [originalSpan])
            }

            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [originalSpan])
        }
    }

    /// Provenance coordinates are ProseMirror document positions now, so the store
    /// can no longer check the text a span covers — slicing Markdown by a document
    /// position is meaningless, and hashing that slice dropped every span (a span
    /// over `bold` in `**bold**` hashed `*bol`). The editor owns that check,
    /// because only the editor has the document. What remains here is structural.
    func test_saveStreamDocumentWithSpansDropsStructurallyInvalidRows() throws {
        try withTempPersistenceService { service in
            let stream = Stream(title: "Span Validation")
            try service.saveStream(stream)
            let initialDocument = try service.loadOrCreateStreamDocument(streamId: stream.id)
            let validSpan = ProvenanceSpan(
                spanId: "span-valid",
                streamId: stream.id,
                start: 0,
                end: 5,
                origin: "ai",
                textHash: FNV1a.hash("Hello"),
                createdAt: Date(timeIntervalSince1970: 2_010)
            )
            // A hash the store cannot verify is kept: only the editor can say
            // whether it matches, and it does so on load.
            let unverifiableHash = ProvenanceSpan(
                spanId: "span-unverifiable-hash",
                streamId: stream.id,
                start: 6,
                end: 11,
                origin: "ai",
                textHash: FNV1a.hash("checked in the editor"),
                createdAt: Date(timeIntervalSince1970: 2_011)
            )
            let negative = ProvenanceSpan(
                spanId: "span-negative",
                streamId: stream.id,
                start: -1,
                end: 4,
                origin: "ai",
                textHash: FNV1a.hash("bad"),
                createdAt: Date(timeIntervalSince1970: 2_012)
            )
            let inverted = ProvenanceSpan(
                spanId: "span-inverted",
                streamId: stream.id,
                start: 9,
                end: 3,
                origin: "ai",
                textHash: FNV1a.hash("bad"),
                createdAt: Date(timeIntervalSince1970: 2_013)
            )

            _ = try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "Hello world",
                baseRevision: initialDocument.revision,
                spans: [validSpan, unverifiableHash, negative, inverted]
            )

            XCTAssertEqual(try service.loadSpans(streamId: stream.id), [validSpan, unverifiableHash])
        }
    }

    func test_streamCodecPreviewLineSkipsHeadingsAndImages() throws {
        let markdown = """
        # Heading to skip

        ![diagram](ticker-asset://stream/diagram.png)

        First readable line.
        """

        XCTAssertEqual(StreamCodec.previewLine(from: markdown), "First readable line.")
    }

    func test_streamCodecPreviewLineStripsMarkdownMarksAndLinks() throws {
        let markdown = "> **# [Linked idea](https://example.com)** with `code`"

        XCTAssertEqual(StreamCodec.previewLine(from: markdown), "Linked idea with code")
    }

    func test_loadStreamSummariesUsesDocumentMarkdownAndUpdatedAtOrdering() throws {
        try withTempPersistenceService { service in
            let olderStream = Stream(title: "Older Stream")
            let newerStream = Stream(title: "Newer Stream")
            try service.saveStream(olderStream)
            try service.saveStream(newerStream)
            try service.saveSource(SourceReference(
                streamId: newerStream.id,
                displayName: "Notebook.pdf",
                fileType: .pdf,
                bookmarkData: Data("bookmark".utf8),
                status: .ready
            ))

            let olderMarkdown = "# Older Notes\n\nThe older document preview comes from markdown."
            let newerMarkdown = """
            Newer document preview

            ![diagram](ticker-asset://stream/diagram.png)
            ![photo](https://example.com/photo.jpg)

            Second paragraph.
            """
            _ = try service.saveStreamDocument(
                streamId: olderStream.id,
                markdown: olderMarkdown
            )
            Thread.sleep(forTimeInterval: 0.01)
            _ = try service.saveStreamDocument(
                streamId: newerStream.id,
                markdown: newerMarkdown
            )

            let summaries = try service.loadStreamSummaries()

            XCTAssertEqual(summaries.map(\.id), [newerStream.id, olderStream.id])
            XCTAssertGreaterThan(
                try XCTUnwrap(summaries.first?.updatedAt.timeIntervalSince1970),
                try XCTUnwrap(summaries.dropFirst().first?.updatedAt.timeIntervalSince1970)
            )

            let newerSummary = try XCTUnwrap(summaries.first { $0.id == newerStream.id })
            XCTAssertEqual(newerSummary.previewPrefix, String(newerMarkdown.prefix(2_000)))
            XCTAssertEqual(newerSummary.sourceCount, 1)
            XCTAssertEqual(newerSummary.sourceShortTitle, "Notebook")
            XCTAssertEqual(newerSummary.charCount, newerMarkdown.count)
            XCTAssertEqual(newerSummary.wordCount, newerMarkdown.split { $0.isWhitespace }.count)
            XCTAssertEqual(newerSummary.imageCount, 2)

            let olderSummary = try XCTUnwrap(summaries.first { $0.id == olderStream.id })
            XCTAssertEqual(olderSummary.previewPrefix, String(olderMarkdown.prefix(2_000)))
            XCTAssertEqual(olderSummary.charCount, olderMarkdown.count)
            XCTAssertEqual(olderSummary.imageCount, 0)

            let payload = StreamCodec.encodeSummaries([newerSummary])
            let encodedStreams = try XCTUnwrap(payload["streams"]?.value as? [[String: Any]])
            let encodedSummary = try XCTUnwrap(encodedStreams.first)
            XCTAssertEqual(encodedSummary["previewLine"] as? String, "Newer document preview")
            XCTAssertEqual(encodedSummary["sourceShortTitle"] as? String, "Notebook")
            XCTAssertEqual(encodedSummary["wordCount"] as? Int, newerMarkdown.split { $0.isWhitespace }.count)
            XCTAssertEqual(encodedSummary["charCount"] as? Int, newerMarkdown.count)
            XCTAssertNil(encodedSummary["previewText"])

            _ = try service.appendToStreamDocument(streamId: olderStream.id, fragment: "three appended words")
            let appendedSummary = try XCTUnwrap(service.loadStreamSummaries().first { $0.id == olderStream.id })
            XCTAssertEqual(appendedSummary.wordCount, olderMarkdown.split { $0.isWhitespace }.count + 3)
        }
    }

    func test_textSearchFindsStreamDocumentWithSnippet() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Searchable Stream")
            try service.saveStream(stream)
            try service.saveStreamDocument(
                streamId: stream.id,
                markdown: """
                # Research Notes

                This stream document contains a retargeted search phrase for SQL coverage.

                The surrounding markdown should appear in the result snippet.
                """
            )

            let retrievalService = RetrievalService(persistence: service)
            let searchService = SearchService(
                persistence: service,
                retrieval: retrievalService
            )

            let results = try await searchService.hybridSearch(
                query: "retargeted search phrase",
                currentStreamId: stream.id,
                limit: 5
            )

            let result = try XCTUnwrap(results.currentStreamResults.first)
            XCTAssertEqual(result.streamId, stream.id.uuidString)
            XCTAssertEqual(result.streamTitle, "Searchable Stream")
            XCTAssertEqual(result.sourceType.rawValue, "document")
            XCTAssertEqual(result.title, "Research Notes")
            XCTAssertTrue(result.snippet.contains("retargeted search phrase"))
            XCTAssertTrue(results.otherStreamResults.isEmpty)
        }
    }

    func test_hybridSearchWithoutCurrentStreamReturnsAllMatchesAsOtherStreams() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Listed Stream")
            try service.saveStream(stream)
            try service.saveStreamDocument(
                streamId: stream.id,
                markdown: "A globally findable phrase."
            )
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Global Manual.pdf",
                extractedText: "A globally findable source phrase.",
                aiExcluded: true,
                chunks: [(0, "A globally findable source phrase.", 3, 3, nil)]
            )

            let searchService = SearchService(
                persistence: service,
                retrieval: RetrievalService(persistence: service)
            )

            let results = try await searchService.hybridSearch(
                query: "globally findable",
                currentStreamId: nil,
                limit: 5
            )

            XCTAssertTrue(results.currentStreamResults.isEmpty)
            XCTAssertEqual(results.otherStreamResults.first?.streamId, stream.id.uuidString)
            XCTAssertTrue(results.otherStreamResults.contains {
                $0.sourceType.rawValue == "chunk" && $0.sourceName == "Global Manual.pdf"
            })
        }
    }

    func test_hybridSearchGroupsOtherStreamSourceMatches() async throws {
        try await withTempPersistenceService { service in
            let current = Stream(title: "Current")
            let other = Stream(title: "Other")
            try service.saveStream(current)
            try service.saveStream(other)
            _ = try saveRetrievalSource(
                in: service,
                streamId: other.id,
                displayName: "Remote Notes.md",
                extractedText: "The copper astrolabe appears here.",
                chunks: [(0, "The copper astrolabe appears here.", 1, 1, nil)]
            )

            let results = try await SearchService(
                persistence: service,
                retrieval: RetrievalService(persistence: service)
            ).hybridSearch(query: "copper astrolabe", currentStreamId: current.id, limit: 5)

            XCTAssertTrue(results.currentStreamResults.isEmpty)
            let match = try XCTUnwrap(results.otherStreamResults.first)
            XCTAssertEqual(match.streamId, other.id.uuidString)
            XCTAssertEqual(match.streamTitle, "Other")
            XCTAssertEqual(match.sourceName, "Remote Notes.md")
        }
    }

    func test_hybridSearchStillFindsAIExcludedSourceChunksLocally() async throws {
        try await withTempPersistenceService { service in
            let stream = Stream(title: "Local Private Search")
            try service.saveStream(stream)
            _ = try saveRetrievalSource(
                in: service,
                streamId: stream.id,
                displayName: "Private.pdf",
                extractedText: largeExtractedText("private"),
                aiExcluded: true,
                chunks: stronglyRelevantChunks(
                    strongText: "privatephrase privatephrase privatephrase local local local",
                    pageStart: 7,
                    pageEnd: 7
                )
            )

            let searchService = SearchService(
                persistence: service,
                retrieval: RetrievalService(persistence: service)
            )

            let results = try await searchService.hybridSearch(
                query: "privatephrase",
                currentStreamId: stream.id,
                limit: 5
            )

            let chunkResult = try XCTUnwrap(
                results.currentStreamResults.first { $0.sourceType.rawValue == "chunk" }
            )
            XCTAssertEqual(chunkResult.sourceName, "Private.pdf")
            XCTAssertTrue(chunkResult.snippet.contains("privatephrase"))
        }
    }

    func test_migrationBackupIsCreatedWhenExistingDatabaseHasPendingMigrations() throws {
        try withSeededV10Database { _ in
            // v10 is intentionally behind the service's registered migrations.
        } body: { dbURL, fileManager in
            _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            XCTAssertEqual(
                try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).count,
                1
            )
        }
    }

    func test_sidenoteMigrationsBackUpAndPreserveProductionShapedDatabase() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")
        defer { _ = try? fileManager.removeItem(at: tempDir) }

        let stream = Stream(title: "Existing project")
        let source = SourceReference(
            streamId: stream.id,
            displayName: "Existing.pdf",
            fileType: .pdf,
            bookmarkData: Data("bookmark".utf8),
            status: .ready
        )
        let highlight = PDFHighlightRecord(
            id: UUID(),
            sourceId: source.id,
            page: 5,
            rects: [PDFHighlightRect(page: 5, x: 1, y: 2, w: 3, h: 4)],
            quote: "Existing evidence",
            createdAt: Date(timeIntervalSince1970: 5_000)
        )
        let exchange = AIExchange(
            requestId: "existing-exchange",
            streamId: stream.id,
            verb: "ask",
            userInput: "Existing prompt",
            responseRaw: "Existing answer",
            createdAt: Date(timeIntervalSince1970: 5_001)
        )
        let prototypeThread = StreamThread(
            streamId: stream.id,
            title: "Existing sidenote",
            workingText: "Existing draft",
            docJSON: #"{"type":"doc","content":[]}"#,
            docFormatVersion: 1,
            anchorText: "Existing passage",
            anchorSpanId: "existing-span",
            createdAt: Date(timeIntervalSince1970: 5_002),
            updatedAt: Date(timeIntervalSince1970: 5_003)
        )
        let prototypeAnchor = StreamThreadAnchor(
            anchorId: "existing-anchor",
            threadId: prototypeThread.threadId,
            kind: .streamQuote,
            quote: prototypeThread.anchorText,
            anchorSpanId: prototypeThread.anchorSpanId,
            createdAt: prototypeThread.createdAt
        )

        var service: PersistenceService? = try PersistenceService(
            databaseURL: dbURL,
            fileManager: fileManager,
            usesAppendInbox: true
        )
        try service?.saveStream(stream)
        try service?.saveSource(source)
        try service?.savePDFHighlight(highlight)
        try service?.saveExchange(exchange)
        try service?.createStreamThread(prototypeThread, anchors: [prototypeAnchor])
        service = nil

        // Turn the fresh database into the exact released v29 shape while preserving
        // representative prototype data. Reopening it must run the real v30 migrator.
        var dbQueue: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try dbQueue?.write { db in
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN ephemeral")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN detached")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN anchor_end")
            try db.execute(sql: "ALTER TABLE stream_threads DROP COLUMN anchor_start")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v30_conversation_anchors'")
        }
        dbQueue = nil

        service = try PersistenceService(
            databaseURL: dbURL,
            fileManager: fileManager,
            usesAppendInbox: true
        )
        XCTAssertEqual(try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).count, 1)
        XCTAssertEqual(try service?.loadStream(id: stream.id)?.title, stream.title)
        XCTAssertEqual(try service?.loadSource(id: source.id)?.displayName, source.displayName)
        XCTAssertEqual(try service?.loadPDFHighlights(sourceId: source.id), [highlight])
        XCTAssertEqual(try service?.loadExchange(requestId: exchange.requestId), exchange)
        let migratedThread = try XCTUnwrap(service?.loadStreamThreads(streamId: stream.id).first)
        XCTAssertEqual(migratedThread.threadId, prototypeThread.threadId)
        XCTAssertEqual(migratedThread.title, prototypeThread.title)
        XCTAssertEqual(migratedThread.workingText, prototypeThread.workingText)
        XCTAssertEqual(migratedThread.docJSON, prototypeThread.docJSON)
        XCTAssertEqual(migratedThread.docFormatVersion, prototypeThread.docFormatVersion)
        XCTAssertEqual(migratedThread.anchorText, prototypeThread.anchorText)
        XCTAssertNil(migratedThread.anchorStart)
        XCTAssertNil(migratedThread.anchorEnd)
        XCTAssertTrue(migratedThread.detached)
        XCTAssertFalse(migratedThread.ephemeral)
        XCTAssertEqual(
            try service?.loadStreamThreadAnchors(
                threadId: prototypeThread.threadId,
                streamId: stream.id
            ),
            [prototypeAnchor]
        )
        service = nil

        let backupURL = try XCTUnwrap(preMigrationBackups(nextTo: dbURL, fileManager: fileManager).first)
        let backupQueue = try DatabaseQueue(path: backupURL.path)
        try backupQueue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            let exchangeColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(ai_exchanges)")
                .map { (row: Row) -> String in row["name"] }
            let threadColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(stream_threads)")
                .map { (row: Row) -> String in row["name"] }
            let storedAnswer = try String.fetchOne(
                db,
                sql: "SELECT response_raw FROM ai_exchanges WHERE request_id = ?",
                arguments: [exchange.requestId]
            )
            let storedThreadTitle = try String.fetchOne(
                db,
                sql: "SELECT title FROM stream_threads WHERE thread_id = ?",
                arguments: [prototypeThread.threadId.uuidString]
            )
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")

            XCTAssertTrue(tables.contains("stream_threads"))
            XCTAssertTrue(tables.contains("stream_thread_anchors"))
            XCTAssertTrue(exchangeColumns.contains("thread_id"))
            XCTAssertTrue(exchangeColumns.contains("thread_disposition"))
            XCTAssertTrue(threadColumns.contains("doc_json"))
            XCTAssertTrue(threadColumns.contains("doc_format_version"))
            XCTAssertFalse(threadColumns.contains("anchor_start"))
            XCTAssertFalse(threadColumns.contains("anchor_end"))
            XCTAssertFalse(threadColumns.contains("detached"))
            XCTAssertFalse(threadColumns.contains("ephemeral"))
            XCTAssertTrue(migrations.contains("v29_sidenote_documents"))
            XCTAssertFalse(migrations.contains("v30_conversation_anchors"))
            XCTAssertEqual(storedAnswer, exchange.responseRaw)
            XCTAssertEqual(storedThreadTitle, prototypeThread.title)
        }
    }

    func test_migrationBackupIsNotCreatedWhenExistingDatabaseHasNoPendingMigrations() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        _ = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        XCTAssertEqual(
            try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).count,
            0
        )
    }

    func test_migrationBackupFailurePreventsMigration() throws {
        try withSeededV10Database { _ in
            // v10 is intentionally behind the service's registered migrations.
        } body: { dbURL, fileManager in
            let backupsDirectory = dbURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: backupsDirectory.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupsDirectory.path)
            }

            XCTAssertThrowsError(try PersistenceService(databaseURL: dbURL, fileManager: fileManager))

            let dbQueue = try DatabaseQueue(path: dbURL.path)
            let migrationCount = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
            }
            XCTAssertEqual(migrationCount, 10)
        }
    }

    func test_v11MigrationRecoversPostDocumentQuickPanelCellsInOrder() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Recover Later Cells", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Existing document",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>First recovered note</p>",
                createdAt: documentCreatedAt + 1,
                position: 0
            )
            try insertCell(
                db,
                streamId: streamId,
                content: #"<p><img src="ticker-asset:///abc/img.png" alt="Screenshot"></p>"#,
                createdAt: documentCreatedAt + 2,
                position: 1
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            try assertPreMigrationBackupExists(nextTo: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertTrue(document.markdown.hasSuffix("""
            ## Recovered captures

            First recovered note

            ![capture](ticker-asset:///abc/img.png)
            """))
        }
    }

    func test_v12MigrationDoesNotTouchStreamsWithExistingDocumentRow() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Already Seeded", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Already folded legacy note",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Already folded legacy note</p>",
                createdAt: documentCreatedAt - 1,
                position: 0
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertEqual(document.markdown, "Already folded legacy note")
        }
    }

    func test_v12MigrationSeedsDocumentForCellOnlyStream() throws {
        let streamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Cell-only Stream", createdAt: 900)
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Second legacy note</p>",
                createdAt: 1_002,
                position: 1
            )
            try insertCell(
                db,
                streamId: streamId,
                content: #"<p><img src="ticker-asset:///stream/capture.png" alt="Screenshot"></p>"#,
                createdAt: 1_003,
                position: 1
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>First legacy note</p>",
                createdAt: 1_001,
                position: 0
            )
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            let document = try XCTUnwrap(service.loadStreamDocument(streamId: streamId))
            XCTAssertEqual(document.markdown, """
            First legacy note

            Second legacy note

            ![capture](ticker-asset:///stream/capture.png)
            """)
        }
    }

    func test_v12MigrationDoesNotCreateDocumentForStreamWithoutCells() throws {
        let streamId = UUID()

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "Empty Legacy Stream", createdAt: 900)
        } body: { dbURL, fileManager in
            let service = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)

            XCTAssertNil(try service.loadStreamDocument(streamId: streamId))

            let document = try service.loadOrCreateStreamDocument(streamId: streamId)
            XCTAssertEqual(document.markdown, "")
        }
    }

    func test_v11MigrationIsNoOpAfterAlreadyApplied() throws {
        let streamId = UUID()
        let documentCreatedAt = 1_000.0

        try withSeededV10Database { db in
            try insertStream(db, id: streamId, title: "No-op", createdAt: 900)
            try insertStreamDocument(
                db,
                streamId: streamId,
                markdown: "Existing document",
                createdAt: documentCreatedAt
            )
            try insertCell(
                db,
                streamId: streamId,
                content: "<p>Recovered once</p>",
                createdAt: documentCreatedAt + 1,
                position: 0
            )
        } body: { dbURL, fileManager in
            var firstService: PersistenceService? = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
            let firstMarkdown = try XCTUnwrap(firstService?.loadStreamDocument(streamId: streamId)).markdown
            firstService = nil

            let secondService = try PersistenceService(databaseURL: dbURL, fileManager: fileManager)
            let secondMarkdown = try XCTUnwrap(secondService.loadStreamDocument(streamId: streamId)).markdown

            XCTAssertEqual(secondMarkdown, firstMarkdown)
            XCTAssertEqual(
                secondMarkdown,
                "Existing document\n\n## Recovered captures\n\nRecovered once"
            )
        }
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func withTempPersistenceService(
        usesAppendInbox: Bool = false,
        _ body: (PersistenceService) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var service: PersistenceService? = try PersistenceService(
            databaseURL: dbURL,
            fileManager: fileManager,
            usesAppendInbox: usesAppendInbox
        )
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

    private func withTempPersistenceService(_ body: (PersistenceService) async throws -> Void) async throws {
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

        try await body(service)
    }

    private func withTempPersistenceServiceAndURL(
        _ body: (PersistenceService, URL, FileManager) throws -> Void
    ) throws {
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

        try body(service, dbURL, fileManager)
    }

    private func savePDFSource(in service: PersistenceService) throws -> SourceReference {
        let stream = Stream(title: "PDF Highlights")
        try service.saveStream(stream)

        let source = SourceReference(
            streamId: stream.id,
            displayName: "Document.pdf",
            fileType: .pdf,
            bookmarkData: Data("bookmark".utf8),
            status: .ready
        )
        try service.saveSource(source)
        return source
    }

    private func saveRetrievalSource(
        in service: PersistenceService,
        streamId: UUID,
        displayName: String,
        extractedText: String,
        indexStatus: SourceIndexStatus = .ready,
        aiExcluded: Bool = false,
        addedAt: Date = Date(),
        chunks chunkFixtures: [RetrievalChunkFixture] = []
    ) throws -> SourceReference {
        let source = SourceReference(
            streamId: streamId,
            displayName: displayName,
            fileType: .pdf,
            bookmarkData: Data("bookmark-\(displayName)".utf8),
            status: .ready,
            extractedText: extractedText,
            pageCount: 20,
            indexStatus: indexStatus,
            aiExcluded: aiExcluded,
            addedAt: addedAt
        )
        try service.saveSource(source)

        let chunks = chunkFixtures.map { fixture in
            SourceChunk(
                sourceId: source.id,
                seq: fixture.seq,
                text: fixture.text,
                pageStart: fixture.pageStart,
                pageEnd: fixture.pageEnd,
                sectionPath: fixture.sectionPath
            )
        }
        try service.saveSourceChunks(chunks, for: source.id)
        return source
    }

    private func largeExtractedText(_ marker: String = "large") -> String {
        String(repeating: "\(marker) source context. ", count: 2_500)
    }

    private func stronglyRelevantChunks(
        strongText: String,
        pageStart: Int,
        pageEnd: Int,
        sectionPath: String? = nil
    ) -> [RetrievalChunkFixture] {
        genericRetrievalFillerChunks(count: 40, startingSeq: 1)
            + [(0, strongText, pageStart, pageEnd, sectionPath)]
    }

    private func weakUnrelatedChunks() -> [RetrievalChunkFixture] {
        var chunks = genericRetrievalFillerChunks(count: 40, startingSeq: 0)
        var seq = chunks.count
        for token in ["good", "dish", "party", "friends"] {
            for index in 0..<10 {
                chunks.append((
                    seq,
                    "\(token) compiler pipeline register cache \(index)",
                    seq + 1,
                    seq + 1,
                    nil
                ))
                seq += 1
            }
        }
        return chunks
    }

    private func genericRetrievalFillerChunks(count: Int, startingSeq: Int) -> [RetrievalChunkFixture] {
        (0..<count).map { offset in
            let seq = startingSeq + offset
            return (
                seq,
                "technical parser runtime buffer queue memory index compiler register module \(seq)",
                seq + 1,
                seq + 1,
                nil
            )
        }
    }

    private func withSeededV10Database(
        seed: (Database) throws -> Void,
        body: (URL, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var dbQueue: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try dbQueue?.write { db in
            try createV10Schema(db)
            try seed(db)
            try markV10MigrationsApplied(db)
        }
        dbQueue = nil

        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        try body(dbURL, fileManager)
    }

    private func withSeededV15Database(
        seed: (Database) throws -> Void,
        body: (URL, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("ticker.db")

        var dbQueue: DatabaseQueue? = try DatabaseQueue(path: dbURL.path)
        try dbQueue?.write { db in
            try createV15Schema(db)
            try seed(db)
            try markV15MigrationsApplied(db)
        }
        dbQueue = nil

        defer {
            _ = try? fileManager.removeItem(at: tempDir)
        }

        try body(dbURL, fileManager)
    }

    private func createV10Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE streams (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE sources (
                id TEXT PRIMARY KEY,
                stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                file_type TEXT NOT NULL,
                bookmark_data BLOB NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                extracted_text TEXT,
                page_count INTEGER,
                added_at DOUBLE NOT NULL,
                embedding_status TEXT DEFAULT 'none'
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_sources_stream ON sources(stream_id)")
        try db.execute(sql: """
            CREATE TABLE cells (
                id TEXT PRIMARY KEY,
                stream_id TEXT NOT NULL REFERENCES streams(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'idle',
                source_binding_json TEXT,
                metadata_json TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL,
                position INTEGER NOT NULL,
                restatement TEXT,
                original_prompt TEXT,
                modifiers_json TEXT,
                versions_json TEXT,
                active_version_id TEXT,
                processing_config_json TEXT,
                references_json TEXT,
                block_name TEXT,
                source_app TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_cells_stream ON cells(stream_id)")
        try db.execute(sql: "CREATE INDEX idx_cells_position ON cells(stream_id, position)")
        try db.execute(sql: """
            CREATE TABLE stream_documents (
                stream_id TEXT PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
                markdown TEXT NOT NULL DEFAULT '',
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    }

    private func createV15Schema(_ db: Database) throws {
        try createV10Schema(db)

        try db.execute(sql: """
            CREATE TABLE source_chunks (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                token_count INTEGER NOT NULL,
                page_start INTEGER,
                page_end INTEGER,
                embedding_status TEXT NOT NULL DEFAULT 'pending',
                created_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_chunks_source ON source_chunks(source_id)")
        try db.execute(sql: "CREATE INDEX idx_chunks_status ON source_chunks(embedding_status)")
        try db.execute(sql: """
            CREATE TABLE chunk_embeddings (
                chunk_id TEXT PRIMARY KEY REFERENCES source_chunks(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL,
                model TEXT NOT NULL,
                created_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "ALTER TABLE stream_documents ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: """
            CREATE TABLE pdf_highlights (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                page INTEGER NOT NULL,
                rects_json TEXT NOT NULL,
                quote TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_pdf_highlights_source ON pdf_highlights(source_id)")
        try db.execute(sql: "ALTER TABLE sources ADD COLUMN original_path TEXT")
    }

    private func markV10MigrationsApplied(_ db: Database) throws {
        for identifier in [
            "v1_initial",
            "v2_cell_restatement",
            "v3_cell_original_prompt",
            "v4_modifier_stack",
            "v5_processing",
            "v6_fix_source_status",
            "v7_rag_pipeline",
            "v8_quick_panel",
            "v9_heading_in_content_titles",
            "v10_stream_documents"
        ] {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier]
            )
        }
    }

    private func markV15MigrationsApplied(_ db: Database) throws {
        for identifier in [
            "v1_initial",
            "v2_cell_restatement",
            "v3_cell_original_prompt",
            "v4_modifier_stack",
            "v5_processing",
            "v6_fix_source_status",
            "v7_rag_pipeline",
            "v8_quick_panel",
            "v9_heading_in_content_titles",
            "v10_stream_documents",
            "v11_recover_orphaned_quickpanel_cells",
            "v12_seed_documents_from_legacy_cells",
            "v13_stream_document_revision",
            "v14_pdf_highlights",
            "v15_source_original_path"
        ] {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier]
            )
        }
    }

    private func insertStream(_ db: Database, id: UUID, title: String, createdAt: Double) throws {
        try db.execute(
            sql: """
                INSERT INTO streams (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [id.uuidString, title, createdAt, createdAt]
        )
    }

    private func insertV15Source(
        _ db: Database,
        id: UUID,
        streamId: UUID,
        displayName: String,
        fileType: String,
        pageCount: Int?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sources (
                    id,
                    stream_id,
                    display_name,
                    file_type,
                    bookmark_data,
                    status,
                    extracted_text,
                    page_count,
                    added_at,
                    embedding_status,
                    original_path
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id.uuidString,
                streamId.uuidString,
                displayName,
                fileType,
                Data("bookmark".utf8),
                "ready",
                "legacy extracted text",
                pageCount,
                1_000,
                "none",
                nil
            ]
        )
    }

    private func insertStreamDocument(
        _ db: Database,
        streamId: UUID,
        markdown: String,
        createdAt: Double
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO stream_documents (stream_id, markdown, created_at, updated_at)
                VALUES (?, ?, ?, ?)
            """,
            arguments: [streamId.uuidString, markdown, createdAt, createdAt]
        )
    }

    private func insertCell(
        _ db: Database,
        streamId: UUID,
        content: String,
        createdAt: Double,
        position: Int
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cells (
                    id,
                    stream_id,
                    type,
                    content,
                    state,
                    metadata_json,
                    created_at,
                    updated_at,
                    position
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString,
                streamId.uuidString,
                "quote",
                content,
                "idle",
                "{}",
                createdAt,
                createdAt,
                position
            ]
        )
    }

    private func assertPreMigrationBackupExists(nextTo dbURL: URL, fileManager: FileManager) throws {
        XCTAssertTrue(
            try preMigrationBackups(nextTo: dbURL, fileManager: fileManager).isEmpty == false,
            "Expected pre-migration backup for existing DB with pending v11 migration"
        )
    }

    private func preMigrationBackups(nextTo dbURL: URL, fileManager: FileManager) throws -> [URL] {
        let backupsDirectory = dbURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        guard fileManager.fileExists(atPath: backupsDirectory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "db" }
    }

    private func makePDFDocument(pages: [String]) throws -> PDFDocument {
        let data = try makePDFData(pages: pages)
        guard let document = PDFDocument(data: data) else {
            throw TestPDFError.creationFailed
        }
        return document
    }

    private func makePNG(
        width: Int = 1,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let bytes = bitmap.bitmapData else {
            throw TestPDFError.creationFailed
        }

        for pixel in 0..<width {
            let offset = pixel * 4
            bytes[offset] = red
            bytes[offset + 1] = green
            bytes[offset + 2] = blue
            bytes[offset + 3] = 255
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw TestPDFError.creationFailed
        }
        return data
    }

    private func makePDFData(pages: [String]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw TestPDFError.creationFailed
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestPDFError.creationFailed
        }

        for text in pages {
            context.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext

            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor.black
                ]
            )
            attributed.draw(in: CGRect(x: 72, y: 650, width: 468, height: 80))

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    private func addOutline(to document: PDFDocument, labels: [String]) throws {
        let root = PDFOutline()
        for (index, label) in labels.enumerated() {
            guard let page = document.page(at: index) else {
                throw TestPDFError.creationFailed
            }
            let outline = PDFOutline()
            outline.label = label
            outline.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 0))
            root.insertChild(outline, at: root.numberOfChildren)
        }
        document.outlineRoot = root
    }
}
