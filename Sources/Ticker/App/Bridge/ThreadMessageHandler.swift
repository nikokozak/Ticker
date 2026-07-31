import Foundation

@MainActor
final class ThreadMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "listStreamThreads",
        "createStreamThread",
        "loadStreamThread",
        "saveStreamThread"
    ]

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

        switch message.type {
        case "listStreamThreads":
            guard let streamId = decodeUUID(message.payload, key: "streamId") else {
                respondWithError(callbackId, "Invalid listStreamThreads payload")
                return
            }
            do {
                guard try persistence.loadStream(id: streamId) != nil else {
                    throw StreamThreadPersistenceError.streamNotFound
                }
                let threads = try persistence.loadStreamThreads(streamId: streamId)
                let payload = try threads.map { try encodeThread($0, includeExchanges: false) }
                respond(callbackId, ["threads": AnyCodable(payload)])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "createStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let title = payload["title"]?.value as? String,
                  let anchorText = payload["anchorText"]?.value as? String,
                  let anchorSpanIdRaw = payload["anchorSpanId"]?.value as? String,
                  let sourceIdRaw = payload["sourceId"]?.value as? String,
                  let highlightIdRaw = payload["highlightId"]?.value as? String,
                  (sourceIdRaw.isEmpty || UUID(uuidString: sourceIdRaw) != nil),
                  (highlightIdRaw.isEmpty || UUID(uuidString: highlightIdRaw) != nil) else {
                respondWithError(callbackId, "Invalid createStreamThread payload")
                return
            }
            do {
                let thread = try persistence.createStreamThread(StreamThread(
                    streamId: streamId,
                    title: title,
                    anchorText: anchorText,
                    anchorSpanId: anchorSpanIdRaw.isEmpty ? nil : anchorSpanIdRaw,
                    sourceId: UUID(uuidString: sourceIdRaw),
                    highlightId: UUID(uuidString: highlightIdRaw)
                ))
                respond(callbackId, [
                    "thread": AnyCodable(try encodeThread(thread, includeExchanges: true))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "loadStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId") else {
                respondWithError(callbackId, "Invalid loadStreamThread payload")
                return
            }
            do {
                guard let thread = try persistence.loadStreamThread(
                    threadId: threadId,
                    streamId: streamId
                ) else {
                    throw StreamThreadPersistenceError.threadNotFound
                }
                respond(callbackId, [
                    "thread": AnyCodable(try encodeThread(thread, includeExchanges: true))
                ])
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        case "saveStreamThread":
            guard let payload = message.payload,
                  let streamId = decodeUUID(payload, key: "streamId"),
                  let threadId = decodeUUID(payload, key: "threadId"),
                  let title = payload["title"]?.value as? String,
                  let workingText = payload["workingText"]?.value as? String,
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
                    workingText: workingText,
                    baseRevision: baseRevision
                )
                respond(callbackId, [
                    "conflict": AnyCodable(false),
                    "thread": AnyCodable(try encodeThread(thread, includeExchanges: true))
                ])
            } catch let conflict as StreamThreadRevisionConflict {
                do {
                    respond(callbackId, [
                        "conflict": AnyCodable(true),
                        "thread": AnyCodable(try encodeThread(conflict.current, includeExchanges: true))
                    ])
                } catch {
                    respondWithError(callbackId, error.localizedDescription)
                }
            } catch {
                respondWithError(callbackId, error.localizedDescription)
            }

        default:
            respondWithError(callbackId, "Unknown thread message type")
        }
    }

    private func encodeThread(
        _ thread: StreamThread,
        includeExchanges: Bool
    ) throws -> [String: Any] {
        let source = try thread.sourceId.flatMap { try persistence.loadSource(id: $0) }
        let highlight = try source.flatMap { source in
            try thread.highlightId.flatMap {
                try persistence.loadPDFHighlight(id: $0, sourceId: source.id)
            }
        }
        let exchanges = includeExchanges
            ? try persistence.loadThreadExchanges(threadId: thread.threadId, streamId: thread.streamId)
            : nil
        return StreamCodec.encodeThread(
            thread,
            source: source,
            highlight: highlight,
            exchanges: exchanges
        )
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
