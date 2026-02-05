import WebKit

/// Message structure for Swift ↔ JS communication
struct BridgeMessage: Codable {
    let type: String
    let payload: [String: AnyCodable]?
    let callbackId: String?

    init(type: String, payload: [String: AnyCodable]? = nil, callbackId: String? = nil) {
        self.type = type
        self.payload = payload
        self.callbackId = callbackId
    }
}

/// Type-erased Codable wrapper for heterogeneous payloads
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        // Handle Optional values passed as `Any` (e.g. `someOptional as Any`).
        // This is common in bridge payload construction; encode nil as `null`,
        // and unwrap `.some` to encode the underlying value.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first?.value {
                try AnyCodable(child).encode(to: encoder)
            } else {
                try container.encodeNil()
            }
            return
        }

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}

/// Handles WKWebView script message communication
final class BridgeService: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var onMessage: ((BridgeMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "bridge" else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: message.body)
            let bridgeMessage = try JSONDecoder().decode(BridgeMessage.self, from: data)
            onMessage?(bridgeMessage)
        } catch {
            print("Failed to decode bridge message: \(error)")
        }
    }

    /// Send a message to JavaScript
    func send(_ message: BridgeMessage) {
        guard let webView else {
            print("Bridge send: No webView available for message: \(message.type)")
            return
        }

        do {
            let data = try JSONEncoder().encode(message)
            guard let json = String(data: data, encoding: .utf8) else {
                print("Bridge send: Failed to encode JSON for message: \(message.type)")
                return
            }

            // Debug: log what we're sending for image-related messages
            if message.type.contains("image") || message.type.contains("Image") {
                print("Bridge send: Sending \(message.type) with JSON length \(json.count)")
            }

            let script = "window.bridge?.receive(\(json))"
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    print("Bridge send error for \(message.type): \(error)")
                } else if message.type.contains("image") || message.type.contains("Image") {
                    print("Bridge send: Successfully sent \(message.type), result: \(String(describing: result))")
                }
            }
        } catch {
            print("Failed to encode bridge message: \(error)")
        }
    }

    /// Send a response to a callback
    func respond(to callbackId: String, with payload: [String: AnyCodable]) {
        let message = BridgeMessage(type: "callback", payload: payload, callbackId: callbackId)
        send(message)
    }

    /// Send an error response
    func respondWithError(to callbackId: String, error: String) {
        let payload: [String: AnyCodable] = [
            "error": AnyCodable(error)
        ]
        let message = BridgeMessage(type: "callback", payload: payload, callbackId: callbackId)
        send(message)
    }
}
