protocol BridgeMessageHandler {
    var handledTypes: Set<String> { get }
    func handle(_ message: BridgeMessage) async
}

final class BridgeRouter {
    private var handlersByType: [String: BridgeMessageHandler] = [:]
    private let bridgeService: BridgeService

    init(bridgeService: BridgeService) {
        self.bridgeService = bridgeService
    }

    func register(_ handler: BridgeMessageHandler) {
        for type in handler.handledTypes {
            if handlersByType[type] != nil {
                DebugLog.log("[BridgeRouter] Replacing handler for message type: \(type)")
            }
            handlersByType[type] = handler
        }
    }

    func route(_ message: BridgeMessage) async {
        guard let handler = handlersByType[message.type] else {
            DebugLog.log("[BridgeRouter] Unknown message type: \(message.type)")
            await bridgeService.sendBridgeError(type: message.type, reason: "Unknown bridge message type")
            return
        }

        await handler.handle(message)
    }
}
