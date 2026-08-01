import Foundation

@MainActor
final class ThreadMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = ["saveStreamThread"]

    private let persistence: PersistenceService
    private let sendToWeb: (BridgeMessage) -> Void
    private let sendBridgeError: (String, String) -> Void

    init?(container: ServiceContainer) {
        guard let persistence = container.persistence else { return nil }
        self.persistence = persistence
        self.sendToWeb = { [bridgeService = container.bridgeService] message in
            bridgeService.send(message)
        }
        self.sendBridgeError = { [bridgeService = container.bridgeService] type, reason in
            bridgeService.sendBridgeError(type: type, reason: reason)
        }
    }

    init(
        persistence: PersistenceService,
        sendToWeb: @escaping (BridgeMessage) -> Void,
        sendBridgeError: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.persistence = persistence
        self.sendToWeb = sendToWeb
        self.sendBridgeError = sendBridgeError
    }

    func handle(_ message: BridgeMessage) async {
        guard let callbackId = message.callbackId else {
            sendBridgeError(message.type, "Missing callbackId for \(message.type)")
            return
        }
        guard message.type == "saveStreamThread",
              let payload = message.payload,
              let streamId = decodeUUID(payload, key: "streamId"),
              let threadId = decodeUUID(payload, key: "threadId"),
              let title = payload["title"]?.value as? String,
              let baseRevision = payload["baseRevision"]?.intValue,
              baseRevision >= 0 else {
            respondWithError(callbackId, "Invalid saveStreamThread payload")
            return
        }

        do {
            let thread = try persistence.saveStreamThread(
                threadId: threadId,
                streamId: streamId,
                title: title,
                baseRevision: baseRevision
            )
            respond(callbackId, [
                "conflict": AnyCodable(false),
                "thread": AnyCodable(StreamCodec.encodeThread(
                    thread,
                    source: nil,
                    highlight: nil,
                    exchanges: nil
                ))
            ])
        } catch let conflict as StreamThreadRevisionConflict {
            respond(callbackId, [
                "conflict": AnyCodable(true),
                "thread": AnyCodable(StreamCodec.encodeThread(
                    conflict.current,
                    source: nil,
                    highlight: nil,
                    exchanges: nil
                ))
            ])
        } catch {
            respondWithError(callbackId, error.localizedDescription)
        }
    }

    private func respond(_ callbackId: String, _ payload: [String: AnyCodable]) {
        sendToWeb(BridgeMessage(type: "callback", payload: payload, callbackId: callbackId))
    }

    private func respondWithError(_ callbackId: String, _ error: String) {
        respond(callbackId, ["error": AnyCodable(error)])
    }

    private func decodeUUID(_ payload: [String: AnyCodable]?, key: String) -> UUID? {
        guard let raw = payload?[key]?.value as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
