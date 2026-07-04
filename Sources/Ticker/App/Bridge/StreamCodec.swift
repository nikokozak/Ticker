import Foundation

enum StreamCodec {
    static func encodeStream(_ stream: Stream, document: StreamDocument) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": stream.id.uuidString,
            "title": stream.title,
            "sources": stream.sources.map { source -> [String: Any] in
                var dict: [String: Any] = [
                    "id": source.id.uuidString,
                    "streamId": source.streamId.uuidString,
                    "displayName": source.displayName,
                    "fileType": source.fileType.rawValue,
                    "status": source.status.rawValue,
                    "embeddingStatus": source.embeddingStatus.rawValue,
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
                "createdAt": formatter.string(from: document.createdAt),
                "updatedAt": formatter.string(from: document.updatedAt)
            ]
        ]
    }

    static func encodeSource(_ source: SourceReference) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": source.id.uuidString,
            "streamId": source.streamId.uuidString,
            "displayName": source.displayName,
            "fileType": source.fileType.rawValue,
            "status": source.status.rawValue,
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
                    "imageCount": summary.imageCount,
                    "updatedAt": formatter.string(from: summary.updatedAt)
                ]
                if let previewText = summary.previewText {
                    dict["previewText"] = previewText
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

    private static func plainTextFromMarkdown(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\!\[([^\]]*)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
