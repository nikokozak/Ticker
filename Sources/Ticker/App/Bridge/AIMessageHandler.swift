import Foundation

struct DocumentAICitationManifestEntry: Equatable {
    let n: Int
    let chunkId: UUID
    let sourceId: UUID
    let page: Int
    let shortTitle: String

    var bridgePayload: [String: Any] {
        [
            "n": n,
            "chunkId": chunkId.uuidString,
            "sourceId": sourceId.uuidString,
            "page": page,
            "shortTitle": shortTitle
        ]
    }
}

enum DocumentAICitationManifest {
    static func entries(from context: SourceContext?) -> [DocumentAICitationManifestEntry]? {
        guard let context,
              context.mode == .retrieved,
              !context.chunks.isEmpty else {
            return nil
        }

        return context.chunks.enumerated().map { index, chunk in
            DocumentAICitationManifestEntry(
                n: index + 1,
                chunkId: chunk.id,
                sourceId: chunk.sourceId,
                page: chunk.pageStart,
                shortTitle: SourceShortTitle.derive(displayName: chunk.sourceName)
            )
        }
    }

    static func bridgePayload(from context: SourceContext?) -> [[String: Any]]? {
        entries(from: context)?.map(\.bridgePayload)
    }

    static func jsonString(from context: SourceContext?) -> String {
        guard let payload = bridgePayload(from: context),
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

private enum DocumentAIVerb: String {
    case develop
    case ask
    case challenge
    case define

    var systemPrompt: String {
        switch self {
        case .develop:
            return Prompts.verbDevelop
        case .ask:
            return Prompts.verbAsk
        case .challenge:
            return Prompts.verbChallenge
        case .define:
            return Prompts.verbDefine
        }
    }
}

private struct DocumentAIChallengeAnchor {
    let start: Int
    let end: Int
    let hash: String
}

enum ReadBackMarginNoteBuilder {
    private struct Item: Decodable {
        let kind: String
        let anchor: String
        let body: String
    }

    private static let allowedKinds: Set<String> = ["question", "tension", "connection"]

    static func build(
        modelOutput: String,
        scopedText: String,
        streamId: UUID,
        scopeStart: Int,
        requestId: String,
        createdAt: Date = Date()
    ) -> (notes: [MarginNote], droppedAnchorCount: Int) {
        guard let data = modelOutput.data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return ([], 0)
        }

        var droppedAnchorCount = 0
        let notes = items.compactMap { item -> MarginNote? in
            let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor = item.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedKinds.contains(kind), !body.isEmpty else {
                return nil
            }
            let anchorWordCount = anchor.split { $0.isWhitespace }.count
            guard (5...15).contains(anchorWordCount),
                  let range = NormalizedTextSearch.utf16Range(of: anchor, in: scopedText),
                  let anchoredText = UTF16Offsets.substring(scopedText, start: range.lowerBound, end: range.upperBound) else {
                droppedAnchorCount += 1
                return nil
            }

            return MarginNote(
                streamId: streamId,
                anchorStart: scopeStart + range.lowerBound,
                anchorEnd: scopeStart + range.upperBound,
                anchorHash: FNV1a.hash(anchoredText),
                kind: kind,
                body: body,
                bodyHash: FNV1a.hash(body),
                requestId: requestId,
                createdAt: createdAt
            )
        }

        return (Array(notes.prefix(5)), droppedAnchorCount)
    }
}

final class AIMessageHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "thinkDocument",
        "readBack",
        "cancelDocumentAI"
    ]

    private let assetService: AssetService
    private let persistence: PersistenceService?
    private let sendToWeb: (BridgeMessage) -> Void
    private let sendBridgeErrorMessage: (String, String) async -> Void
    private let isProxyUsable: () async -> Bool
    private let routeDocumentAI: (
        _ query: String,
        _ retrievalQuery: String?,
        _ queryImages: [String],
        _ streamId: UUID?,
        _ sourceScope: SourceScope,
        _ systemPromptOverride: String,
        _ onChunk: @escaping (String) -> Void,
        _ onComplete: @escaping (SourceContext?) -> Void,
        _ onError: @escaping (Error) -> Void,
        _ onModelSelected: ((String) -> Void)?
    ) async -> Void
    private var inFlightRequests: [String: Task<Void, Never>] = [:]

    init?(container: ServiceContainer) {
        self.assetService = container.assetService
        self.persistence = container.persistence
        self.sendToWeb = { [bridgeService = container.bridgeService] message in
            bridgeService.send(message)
        }
        self.sendBridgeErrorMessage = { [bridgeService = container.bridgeService] type, reason in
            await bridgeService.sendBridgeError(type: type, reason: reason)
        }
        self.isProxyUsable = { [deviceKeyService = container.deviceKeyService] in
            await deviceKeyService.currentState.isUsable
        }
        self.routeDocumentAI = { [orchestrator = container.orchestrator] query, retrievalQuery, queryImages, streamId, sourceScope, systemPromptOverride, onChunk, onComplete, onError, onModelSelected in
            await orchestrator.route(
                query: query,
                queryImages: queryImages,
                streamId: streamId,
                retrievalQuery: retrievalQuery,
                sourceScope: sourceScope,
                priorCells: [],
                systemPromptOverride: systemPromptOverride,
                includeHeading: false,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onModelSelected: onModelSelected
            )
        }
    }

    init(
        assetService: AssetService = AssetService(),
        persistence: PersistenceService? = nil,
        sendToWeb: @escaping (BridgeMessage) -> Void,
        sendBridgeErrorMessage: @escaping (String, String) async -> Void = { _, _ in },
        isProxyUsable: @escaping () async -> Bool = { true },
        routeDocumentAI: @escaping (
            _ query: String,
            _ retrievalQuery: String?,
            _ queryImages: [String],
            _ streamId: UUID?,
            _ sourceScope: SourceScope,
            _ systemPromptOverride: String,
            _ onChunk: @escaping (String) -> Void,
            _ onComplete: @escaping (SourceContext?) -> Void,
            _ onError: @escaping (Error) -> Void,
            _ onModelSelected: ((String) -> Void)?
        ) async -> Void
    ) {
        self.assetService = assetService
        self.persistence = persistence
        self.sendToWeb = sendToWeb
        self.sendBridgeErrorMessage = sendBridgeErrorMessage
        self.isProxyUsable = isProxyUsable
        self.routeDocumentAI = routeDocumentAI
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "thinkDocument":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String,
                  let query = payload["query"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid thinkDocument payload")
                await sendBridgeErrorMessage(message.type, "Invalid thinkDocument payload")
                return
            }

            let imageURLs = payload["imageURLs"]?.value as? [String] ?? []
            let imageDataURLs = assetService.assetsToDataURLs(imageURLs)
            if !imageDataURLs.isEmpty {
                DebugLog.log("ThinkDocument: Converting \(imageURLs.count) images to data URLs")
            }
            let sourceScopeRaw = payload["sourceScope"]?.value as? String
            let sourceScope = SourceScope(rawValue: sourceScopeRaw ?? "") ?? .auto
            let verbRaw = payload["verb"]?.value as? String
            let verb = DocumentAIVerb(rawValue: verbRaw ?? "") ?? .develop
            let challengeAnchor: DocumentAIChallengeAnchor? = {
                guard verb == .challenge,
                      let start = payload["anchorStart"]?.intValue,
                      let end = payload["anchorEnd"]?.intValue,
                      let hash = payload["anchorHash"]?.value as? String,
                      start >= 0,
                      start < end,
                      !hash.isEmpty else {
                    return nil
                }
                return DocumentAIChallengeAnchor(start: start, end: end, hash: hash)
            }()

            var streamIdForRAG: UUID? = nil

            if let streamIdValue = payload["streamId"]?.value as? String,
               let streamId = UUID(uuidString: streamIdValue) {
                streamIdForRAG = streamId
            }
            let hasStreamSources = streamHasSources(streamIdForRAG)

            var resolvedQuery = query
            let cleanedContext = (payload["context"]?.value as? String).flatMap(Self.cleanedDocumentContext)
            if let context = payload["context"]?.value as? String, !context.isEmpty {
                if let cleanContext = Self.cleanedDocumentContext(context) {
                    resolvedQuery = "Regarding this context:\n\"\"\"\n\(cleanContext)\n\"\"\"\n\n\(resolvedQuery)"
                }
            }
            let userInput = Self.userInput(selection: cleanedContext ?? query, prompt: cleanedContext == nil ? "" : query)

            var responseRaw = ""
            var selectedModel: String?
            let onChunk: (String) -> Void = { [weak self] chunk in
                guard !Task.isCancelled else { return }
                responseRaw += chunk
                self?.sendToWeb(BridgeMessage(
                    type: "documentAIChunk",
                    payload: ["requestId": AnyCodable(requestId), "chunk": AnyCodable(chunk)]
                ))
            }
            let onComplete: (SourceContext?) -> Void = { [weak self] sourceContext in
                guard !Task.isCancelled else { return }
                if let streamId = streamIdForRAG, let persistence = self?.persistence {
                    do {
                        try persistence.saveExchange(AIExchange(
                            requestId: requestId,
                            streamId: streamId,
                            verb: verb.rawValue,
                            userInput: userInput,
                            sourceManifest: DocumentAICitationManifest.jsonString(from: sourceContext),
                            responseRaw: responseRaw,
                            model: selectedModel
                        ))
                        DebugLog.log("[AIMessageHandler] Saved exchange \(requestId)")
                    } catch {
                        DebugLog.log("[AIMessageHandler] Failed to save exchange (\(DebugLog.errorSummary(error)))")
                    }
                }
                if verb == .challenge, let streamId = streamIdForRAG, let persistence = self?.persistence {
                    if let challengeAnchor {
                        let body = responseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty {
                            do {
                                try persistence.insertMarginNotes([
                                    MarginNote(
                                        streamId: streamId,
                                        anchorStart: challengeAnchor.start,
                                        anchorEnd: challengeAnchor.end,
                                        anchorHash: challengeAnchor.hash,
                                        kind: "tension",
                                        body: body,
                                        bodyHash: FNV1a.hash(body),
                                        requestId: requestId
                                    )
                                ])
                                let visibleNotes = try persistence.loadMarginNotes(streamId: streamId)
                                self?.sendToWeb(BridgeMessage(type: "marginNotesChanged", payload: [
                                    "streamId": AnyCodable(streamId.uuidString),
                                    "notes": AnyCodable(StreamCodec.encodeMarginNotes(visibleNotes))
                                ]))
                            } catch {
                                DebugLog.log("[AIMessageHandler] Failed to save challenge margin note (\(DebugLog.errorSummary(error)))")
                            }
                        }
                    } else {
                        DebugLog.log("[AIMessageHandler] Challenge completed without anchor; margin note skipped")
                    }
                }

                var payload: [String: AnyCodable] = ["requestId": AnyCodable(requestId)]
                if let citations = DocumentAICitationManifest.bridgePayload(from: sourceContext) {
                    payload["citations"] = AnyCodable(citations)
                }
                if sourceContext?.mode == .retrieved {
                    payload["sourceContextMode"] = AnyCodable("retrieved")
                } else if sourceContext == nil, hasStreamSources {
                    payload["sourceContextMode"] = AnyCodable("none")
                }
                self?.sendToWeb(BridgeMessage(
                    type: "documentAIComplete",
                    payload: payload
                ))
            }
            let onError: (Error) -> Void = { [weak self] error in
                guard !Task.isCancelled else { return }
                var payload: [String: AnyCodable] = [
                    "requestId": AnyCodable(requestId),
                    "error": AnyCodable(error.localizedDescription)
                ]

                if let proxyError = error as? ProxyLLMError {
                    payload["errorCode"] = AnyCodable(proxyError.errorCode)
                    if let proxyRequestId = proxyError.requestId {
                        payload["proxyRequestId"] = AnyCodable(proxyRequestId)
                    }

                    if case .quotaExceeded(let details) = proxyError {
                        payload["quotaScope"] = AnyCodable(details.scope)
                        payload["quotaLimit"] = AnyCodable(details.limit)
                        payload["quotaUsed"] = AnyCodable(details.used)
                        payload["quotaResetAt"] = AnyCodable(details.resetAt)
                    }

                    if case .rateLimited(let retryAfter) = proxyError {
                        if let seconds = retryAfter {
                            payload["retryAfter"] = AnyCodable(seconds)
                        }
                    }
                }

                self?.sendToWeb(BridgeMessage(
                    type: "documentAIError",
                    payload: payload
                ))
            }

            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.inFlightRequests[requestId] = nil
                }

                let proxyUsable = await self.isProxyUsable()

                guard proxyUsable else {
                    await MainActor.run {
                        onError(OrchestratorError.noProviderAvailable)
                    }
                    return
                }

                if Task.isCancelled {
                    return
                }

                await self.routeDocumentAI(
                    resolvedQuery,
                    // Retrieval sees only the user's words; resolvedQuery's
                    // "Regarding this context:" wrapper poisons BM25 scoring.
                    cleanedContext.map { "\(query)\n\($0)" } ?? query,
                    imageDataURLs,
                    streamIdForRAG,
                    sourceScope,
                    verb.systemPrompt,
                    onChunk,
                    onComplete,
                    onError,
                    { [weak self] modelId in
                        guard !Task.isCancelled else { return }
                        selectedModel = modelId
                        self?.sendToWeb(BridgeMessage(
                            type: "documentModelSelected",
                            payload: ["requestId": AnyCodable(requestId), "modelId": AnyCodable(modelId)]
                        ))
                    }
                )
            }
            inFlightRequests[requestId] = task

        case "readBack":
            guard let payload = message.payload,
                  let streamIdValue = payload["streamId"]?.value as? String,
                  let streamId = UUID(uuidString: streamIdValue),
                  let scopeStart = payload["scopeStart"]?.intValue,
                  let scopeEnd = payload["scopeEnd"]?.intValue,
                  let persistence else {
                DebugLog.log("[AIMessageHandler] Invalid readBack payload")
                await sendBridgeErrorMessage(message.type, "Invalid readBack payload")
                return
            }

            let document: StreamDocument
            do {
                document = try persistence.loadOrCreateStreamDocument(streamId: streamId)
            } catch {
                DebugLog.log("[AIMessageHandler] Failed to load stream document for readBack (\(DebugLog.errorSummary(error)))")
                return
            }

            guard scopeStart >= 0,
                  scopeStart < scopeEnd,
                  scopeEnd <= UTF16Offsets.utf16Length(document.markdown),
                  let scopedText = UTF16Offsets.substring(document.markdown, start: scopeStart, end: scopeEnd) else {
                DebugLog.log("[AIMessageHandler] Invalid readBack UTF-16 scope")
                await sendBridgeErrorMessage(message.type, "Invalid readBack scope")
                return
            }

            let requestId = UUID().uuidString
            var responseRaw = ""
            let onChunk: (String) -> Void = { chunk in
                guard !Task.isCancelled else { return }
                responseRaw += chunk
            }
            let onComplete: (SourceContext?) -> Void = { [weak self] _ in
                guard !Task.isCancelled else { return }
                let built = ReadBackMarginNoteBuilder.build(
                    modelOutput: responseRaw,
                    scopedText: scopedText,
                    streamId: streamId,
                    scopeStart: scopeStart,
                    requestId: requestId
                )
                if built.droppedAnchorCount > 0 {
                    DebugLog.log("[AIMessageHandler] Dropped \(built.droppedAnchorCount) readBack note(s) with unverifiable anchors")
                }

                do {
                    let suppressed = try persistence.marginSuppressionHashes(streamId: streamId)
                    var seen = try persistence.nonDismissedMarginNoteBodyHashes(streamId: streamId)
                    let notes = built.notes.filter { note in
                        guard !suppressed.contains(note.bodyHash), !seen.contains(note.bodyHash) else {
                            return false
                        }
                        seen.insert(note.bodyHash)
                        return true
                    }.prefix(5)

                    try persistence.insertMarginNotes(Array(notes))
                    let visibleNotes = try persistence.loadMarginNotes(streamId: streamId)
                    self?.sendToWeb(BridgeMessage(type: "marginNotesChanged", payload: [
                        "streamId": AnyCodable(streamId.uuidString),
                        "notes": AnyCodable(StreamCodec.encodeMarginNotes(visibleNotes))
                    ]))
                } catch {
                    DebugLog.log("[AIMessageHandler] Failed to save readBack margin notes (\(DebugLog.errorSummary(error)))")
                }
            }
            let onError: (Error) -> Void = { error in
                guard !Task.isCancelled else { return }
                DebugLog.log("[AIMessageHandler] readBack failed (\(DebugLog.errorSummary(error)))")
            }

            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.inFlightRequests[requestId] = nil
                }

                guard await self.isProxyUsable() else {
                    onError(OrchestratorError.noProviderAvailable)
                    return
                }

                if Task.isCancelled {
                    return
                }

                await self.routeDocumentAI(
                    "Passage:\n\(scopedText)",
                    scopedText,
                    [],
                    streamId,
                    .auto,
                    Prompts.readBack,
                    onChunk,
                    onComplete,
                    onError,
                    nil
                )
            }
            inFlightRequests[requestId] = task

        case "cancelDocumentAI":
            guard let payload = message.payload,
                  let requestId = payload["requestId"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid cancelDocumentAI payload")
                await sendBridgeErrorMessage(message.type, "Invalid cancelDocumentAI payload")
                return
            }
            inFlightRequests.removeValue(forKey: requestId)?.cancel()
            sendToWeb(BridgeMessage(
                type: "documentAIError",
                payload: [
                    "requestId": AnyCodable(requestId),
                    "error": AnyCodable("Cancelled"),
                    "errorCode": AnyCodable("cancelled")
                ]
            ))

        default:
            DebugLog.log("[AIMessageHandler] Unknown message type: \(message.type)")
        }
    }

    private func streamHasSources(_ streamId: UUID?) -> Bool {
        guard let streamId, let persistence else {
            return false
        }

        do {
            return try persistence.loadStream(id: streamId)?.sources.isEmpty == false
        } catch {
            DebugLog.log("[AIMessageHandler] Failed to load stream sources (\(DebugLog.errorSummary(error)))")
            return false
        }
    }

    private static func cleanedDocumentContext(_ context: String) -> String? {
        let cleaned = context
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func userInput(selection: String, prompt: String) -> String {
        "Selection:\n\(selection)\n\nPrompt:\n\(prompt)"
    }
}
