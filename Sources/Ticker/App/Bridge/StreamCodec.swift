import Foundation

enum StreamCodec {
    static func encodeStream(_ stream: Stream, document: StreamDocument) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
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
            "document": [
                "streamId": document.streamId.uuidString,
                "markdown": document.markdown,
                "revision": document.revision,
                "scrollOffset": document.scrollOffset,
                "createdAt": formatter.string(from: document.createdAt),
                "updatedAt": formatter.string(from: document.updatedAt)
            ]
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
        [
            "requestId": exchange.requestId,
            "streamId": exchange.streamId.uuidString,
            "verb": exchange.verb,
            "userInput": exchange.userInput,
            "sourceManifest": exchange.sourceManifest,
            "responseRaw": exchange.responseRaw,
            "model": exchange.model as Any,
            "createdAt": ISO8601DateFormatter().string(from: exchange.createdAt)
        ]
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
                    "cellCount": summary.cellCount,
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

    /// Format a stream for export as markdown or plain text
    static func formatStreamForExport(stream: Stream, document: StreamDocument, format: String) -> String {
        var output = ""
        let isMarkdown = format == "markdown"

        if isMarkdown {
            output += "# \(stream.title)\n\n"
        } else {
            output += "\(stream.title)\n\n"
        }

        let body = isMarkdown ? document.markdown : plainTextFromMarkdown(document.markdown)
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output += body + "\n\n"
        }

        if !stream.sources.isEmpty {
            output += isMarkdown ? "## Sources\n\n" : "Sources:\n"
            for source in stream.sources {
                output += "- \(source.displayName)\n"
            }
        }

        return output
    }

    static func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidChars).joined(separator: "-")
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

    private static func plainTextFromMarkdown(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\!\[([^\]]*)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
