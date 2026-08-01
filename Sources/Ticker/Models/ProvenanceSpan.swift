import Foundation

struct ProvenanceSpan: Codable, Equatable {
    let spanId: String
    let streamId: UUID
    let start: Int
    let end: Int
    let origin: String
    let requestId: String?
    let sourceId: String?
    let meta: String
    let textHash: String
    let createdAt: Date

    init(
        spanId: String = UUID().uuidString,
        streamId: UUID,
        start: Int,
        end: Int,
        origin: String,
        requestId: String? = nil,
        sourceId: String? = nil,
        meta: String = "{}",
        textHash: String,
        createdAt: Date = Date()
    ) {
        self.spanId = spanId
        self.streamId = streamId
        self.start = start
        self.end = end
        self.origin = origin
        self.requestId = requestId
        self.sourceId = sourceId
        self.meta = meta
        self.textHash = textHash
        self.createdAt = createdAt
    }
}

struct AIExchange: Codable, Equatable {
    let requestId: String
    let streamId: UUID
    let threadId: UUID?
    let verb: String
    let userInput: String
    let sourceManifest: String
    let responseRaw: String
    let model: String?
    let threadDisposition: String?
    let createdAt: Date

    init(
        requestId: String,
        streamId: UUID,
        threadId: UUID? = nil,
        verb: String,
        userInput: String,
        sourceManifest: String = "[]",
        responseRaw: String,
        model: String? = nil,
        threadDisposition: String? = nil,
        createdAt: Date = Date()
    ) {
        self.requestId = requestId
        self.streamId = streamId
        self.threadId = threadId
        self.verb = verb
        self.userInput = userInput
        self.sourceManifest = sourceManifest
        self.responseRaw = responseRaw
        self.model = model
        self.threadDisposition = threadDisposition
        self.createdAt = createdAt
    }
}

enum FNV1a {
    static func hash(_ text: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(format: "%08x", hash)
    }
}

enum UTF16Offsets {
    static func substring(_ s: String, start: Int, end: Int) -> String? {
        guard start >= 0, end >= start, end <= s.utf16.count else {
            return nil
        }

        let utf16Start = s.utf16.index(s.utf16.startIndex, offsetBy: start)
        let utf16End = s.utf16.index(s.utf16.startIndex, offsetBy: end)
        guard let stringStart = String.Index(utf16Start, within: s),
              let stringEnd = String.Index(utf16End, within: s) else {
            return nil
        }

        return String(s[stringStart..<stringEnd])
    }

    static func utf16Length(_ s: String) -> Int {
        s.utf16.count
    }
}
