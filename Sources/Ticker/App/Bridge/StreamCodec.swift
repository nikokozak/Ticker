import Foundation

enum StreamCodec {
    static func encodeStream(_ stream: Stream, document: StreamDocument) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var documentPayload: [String: Any] = [
            "streamId": document.streamId.uuidString,
            "markdown": document.markdown,
            "revision": document.revision,
            "scrollOffset": document.scrollOffset,
            "createdAt": formatter.string(from: document.createdAt),
            "updatedAt": formatter.string(from: document.updatedAt)
        ]
        if let docJSON = document.docJSON, let docFormatVersion = document.docFormatVersion {
            documentPayload["docJSON"] = docJSON
            documentPayload["docFormatVersion"] = docFormatVersion
        }
        return [
            "id": stream.id.uuidString,
            "title": stream.title,
            "sourceScope": stream.sourceScope.rawValue,
            "sources": stream.sources.map { source -> [String: Any] in
                var dict: [String: Any] = [
                    "id": source.id.uuidString,
                    "streamId": source.streamId.uuidString,
                    "displayName": source.displayName,
                    "shortTitle": source.shortTitle,
                    "fileType": source.fileType.rawValue,
                    "status": source.status.rawValue,
                    "embeddingStatus": source.embeddingStatus.rawValue,
                    "indexStatus": source.indexStatus.rawValue,
                    "aiExcluded": source.aiExcluded,
                    "addedAt": formatter.string(from: source.addedAt)
                ]
                if let pageCount = source.pageCount {
                    dict["pageCount"] = pageCount
                }
                return dict
            },
            "createdAt": formatter.string(from: stream.createdAt),
            "updatedAt": formatter.string(from: stream.updatedAt),
            "document": documentPayload
        ]
    }

    static func encodeSpans(_ spans: [ProvenanceSpan]) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return spans.map { span in
            var dict: [String: Any] = [
                "spanId": span.spanId,
                "start": span.start,
                "end": span.end,
                "origin": span.origin,
                "meta": span.meta,
                "textHash": span.textHash,
                "createdAt": formatter.string(from: span.createdAt)
            ]
            if let requestId = span.requestId {
                dict["requestId"] = requestId
            }
            if let sourceId = span.sourceId {
                dict["sourceId"] = sourceId
            }
            return dict
        }
    }

    static func encodeConversationAnchors(_ anchors: [ConversationAnchor]) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return anchors.map { anchor in
            [
                "threadId": anchor.threadId.uuidString,
                "anchorStart": anchor.anchorStart.map { $0 as Any } ?? NSNull(),
                "anchorEnd": anchor.anchorEnd.map { $0 as Any } ?? NSNull(),
                "anchorText": anchor.anchorText,
                "detached": anchor.detached,
                "ephemeral": anchor.ephemeral,
                "updatedAt": formatter.string(from: anchor.updatedAt)
            ]
        }
    }

    static func encodeMarginNotes(_ notes: [MarginNote]) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return notes.map { note in
            var dict: [String: Any] = [
                "noteId": note.noteId,
                "streamId": note.streamId.uuidString,
                "anchorStart": note.anchorStart,
                "anchorEnd": note.anchorEnd,
                "anchorHash": note.anchorHash,
                "kind": note.kind,
                "body": note.body,
                "bodyHash": note.bodyHash,
                "status": note.status,
                "createdAt": formatter.string(from: note.createdAt)
            ]
            if let requestId = note.requestId {
                dict["requestId"] = requestId
            }
            return dict
        }
    }

    static func encodeExchange(_ exchange: AIExchange) -> [String: Any] {
        var payload: [String: Any] = [
            "requestId": exchange.requestId,
            "streamId": exchange.streamId.uuidString,
            "verb": exchange.verb,
            "userInput": exchange.userInput,
            "sourceManifest": exchange.sourceManifest,
            "responseRaw": exchange.responseRaw,
            "model": exchange.model as Any,
            "createdAt": ISO8601DateFormatter().string(from: exchange.createdAt)
        ]
        if let threadId = exchange.threadId {
            payload["threadId"] = threadId.uuidString
        }
        if let disposition = exchange.threadDisposition {
            payload["threadDisposition"] = disposition
        }
        return payload
    }

    static func encodeThread(
        _ thread: StreamThread,
        source: SourceReference?,
        highlight: PDFHighlightRecord?,
        exchanges: [AIExchange]?,
        anchors: [[String: Any]] = []
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "threadId": thread.threadId.uuidString,
            "streamId": thread.streamId.uuidString,
            "title": thread.title,
            "workingText": thread.workingText,
            "anchorText": thread.anchorText,
            "detached": thread.detached,
            "ephemeral": thread.ephemeral,
            "revision": thread.revision,
            "createdAt": formatter.string(from: thread.createdAt),
            "updatedAt": formatter.string(from: thread.updatedAt)
        ]
        if let docJSON = thread.docJSON, let docFormatVersion = thread.docFormatVersion {
            payload["docJSON"] = docJSON
            payload["docFormatVersion"] = docFormatVersion
        }
        if let anchorStart = thread.anchorStart, let anchorEnd = thread.anchorEnd {
            payload["anchorStart"] = anchorStart
            payload["anchorEnd"] = anchorEnd
        }
        payload["anchors"] = anchors
        if let exchanges {
            payload["exchanges"] = exchanges.map(encodeExchange)
        }
        if let anchorSpanId = thread.anchorSpanId {
            payload["anchorSpanId"] = anchorSpanId
        }
        if let source {
            payload["sourceId"] = source.id.uuidString
            payload["sourceName"] = source.displayName
            payload["sourceShortTitle"] = source.shortTitle
        }
        if let highlight {
            payload["highlightId"] = highlight.id.uuidString
            payload["sourcePage"] = highlight.page
        }
        return payload
    }

    static func encodeThreadAnchor(
        _ anchor: StreamThreadAnchor,
        source: SourceReference?,
        highlight: PDFHighlightRecord?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "anchorId": anchor.anchorId,
            "threadId": anchor.threadId.uuidString,
            "kind": anchor.kind.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: anchor.createdAt)
        ]
        if let quote = anchor.quote { payload["quote"] = quote }
        if let anchorSpanId = anchor.anchorSpanId {
            payload["anchorSpanId"] = anchorSpanId
            // ponytail: encode PM positions in the frozen span-id column; add columns if pins become mapped ranges.
            let parts = anchorSpanId.split(separator: ":")
            if parts.count == 3, parts[0] == "pm", let from = Int(parts[1]), let to = Int(parts[2]) {
                payload["anchorStart"] = from
                payload["anchorEnd"] = to
            }
        }
        if let source {
            payload["sourceId"] = source.id.uuidString
            payload["sourceName"] = source.displayName
            payload["sourceShortTitle"] = source.shortTitle
        }
        if let highlight {
            payload["highlightId"] = highlight.id.uuidString
            payload["sourcePage"] = highlight.page
        }
        return payload
    }

    static func encodeSource(_ source: SourceReference) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": source.id.uuidString,
            "streamId": source.streamId.uuidString,
            "displayName": source.displayName,
            "shortTitle": source.shortTitle,
            "fileType": source.fileType.rawValue,
            "status": source.status.rawValue,
            "embeddingStatus": source.embeddingStatus.rawValue,
            "indexStatus": source.indexStatus.rawValue,
            "aiExcluded": source.aiExcluded,
            "addedAt": formatter.string(from: source.addedAt)
        ]
        if let pageCount = source.pageCount {
            dict["pageCount"] = pageCount
        }
        if source.extractedText != nil {
            dict["hasExtractedText"] = true
        }
        return dict
    }

    static func encodeSummaries(_ summaries: [StreamSummary]) -> [String: AnyCodable] {
        let formatter = ISO8601DateFormatter()
        return [
            "streams": AnyCodable(summaries.map { summary -> [String: Any] in
                var dict: [String: Any] = [
                    "id": summary.id.uuidString,
                    "title": summary.title,
                    "sourceCount": summary.sourceCount,
                    "charCount": summary.charCount,
                    "wordCount": summary.wordCount,
                    "imageCount": summary.imageCount,
                    "openQuestionCount": summary.openQuestionCount,
                    "previewLine": previewLine(from: summary.previewPrefix ?? "") ?? "",
                    "updatedAt": formatter.string(from: summary.updatedAt)
                ]
                if let sourceShortTitle = summary.sourceShortTitle {
                    dict["sourceShortTitle"] = sourceShortTitle
                }
                return dict
            })
        ]
    }

    static func previewLine(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { continue }

            let stripped = strippedPreviewMarkdown(trimmed)
            guard !stripped.isEmpty else { continue }
            return stripped
        }
        return nil
    }

    private static func strippedPreviewMarkdown(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^\)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^>+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#*`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The wire form of an append still waiting for an editor to place its
    /// provenance. Built here rather than inline so the payload literal stays
    /// simple enough for the contract checker to read.
    static func encodePendingAppends(_ appends: [PendingStreamAppend]) -> [[String: AnyCodable]] {
        appends.map { append in
            [
                "revision": AnyCodable(append.revision),
                "separator": AnyCodable(append.separator),
                "fragment": AnyCodable(append.fragment),
                "rawSpansJSON": AnyCodable(append.rawSpansJSON)
            ]
        }
    }

    static func encodeAppendInbox(_ appends: [StreamAppendInboxEntry]) -> [[String: AnyCodable]] {
        let formatter = ISO8601DateFormatter()
        return appends.map { append in
            [
                "seq": AnyCodable(append.seq),
                "appendId": AnyCodable(append.appendId),
                "fragment": AnyCodable(append.fragment),
                "rawSpansJSON": AnyCodable(append.rawSpansJSON),
                "createdAt": AnyCodable(formatter.string(from: append.createdAt))
            ]
        }
    }

    static func appendInboxChangedMessage(
        streamId: UUID,
        appends: [StreamAppendInboxEntry],
        isNewStream: Bool,
        source: String
    ) -> BridgeMessage {
        BridgeMessage(type: "streamAppendInboxChanged", payload: [
            "streamId": AnyCodable(streamId.uuidString),
            "appendInbox": AnyCodable(encodeAppendInbox(appends)),
            "isNewStream": AnyCodable(isNewStream),
            "source": AnyCodable(source)
        ])
    }

    static func externalAppendMessage(
        streamId: UUID,
        result: ExternalAppendResult,
        isNewStream: Bool = false,
        source: String
    ) -> BridgeMessage {
        switch result {
        case .legacy(let append):
            return BridgeMessage(type: "streamDocumentAppended", payload: [
                "streamId": AnyCodable(streamId.uuidString),
                "fragment": AnyCodable(append.fragment),
                "revision": AnyCodable(append.revision),
                "isNewStream": AnyCodable(isNewStream),
                "source": AnyCodable(source),
                "spans": AnyCodable(encodeSpans(append.spans))
            ])
        case .inbox(let appends):
            return appendInboxChangedMessage(
                streamId: streamId,
                appends: appends,
                isNewStream: isNewStream,
                source: source
            )
        }
    }
}
