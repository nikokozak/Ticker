import Foundation

/// App composition root for long-lived services.
struct ServiceContainer {
    let settingsService: SettingsService
    let deviceKeyService: DeviceKeyService
    let bridgeService: BridgeService
    let assetService: AssetService
    let proxyService: ProxyLLMService
    let chunkingService: ChunkingService
    let orchestrator: AIOrchestrator
    let persistence: PersistenceService?
    let sourceService: SourceService?
    let ingestService: IngestService?
    let autoTitleService: AutoTitleService?
    let retrievalService: RetrievalService?
    let searchService: SearchService?

    init(
        settingsService: SettingsService = .shared,
        deviceKeyService: DeviceKeyService = .shared
    ) {
        self.settingsService = settingsService
        self.deviceKeyService = deviceKeyService
        self.bridgeService = BridgeService()
        self.assetService = AssetService()

        let proxyService = ProxyLLMService(deviceKeyService: deviceKeyService)
        self.proxyService = proxyService

        self.chunkingService = ChunkingService()

        let orchestrator = AIOrchestrator(
            proxyService: proxyService,
            settings: settingsService
        )
        self.orchestrator = orchestrator

        do {
            let persistence = try PersistenceService()
            self.persistence = persistence

            let sourceService = SourceService(persistence: persistence)
            self.sourceService = sourceService

            self.autoTitleService = AutoTitleService(
                persistence: persistence,
                restatementProvider: proxyService,
                onStreamsChanged: { [bridgeService] in
                    await MainActor.run {
                        bridgeService.send(BridgeMessage(type: "streamsChanged", payload: [:]))
                    }
                }
            )

            let embeddingProvider = MiniLMEmbeddingProvider()
            // Warm the model off the critical path so the first query's semantic
            // leg doesn't hit a cold start (queries never wait on prepare).
            Task.detached(priority: .utility) { _ = await embeddingProvider.prepare() }
            let ingestService = IngestService(
                persistence: persistence,
                sourceService: sourceService,
                chunkingService: chunkingService,
                embeddingProvider: embeddingProvider
            )
            ingestService.onStatusChange = { [bridgeService] update in
                var payload: [String: AnyCodable] = [
                    "sourceId": AnyCodable(update.sourceId.uuidString),
                    "status": AnyCodable(update.status.rawValue)
                ]
                if let progress = update.progress {
                    payload["progress"] = AnyCodable(progress)
                }
                DispatchQueue.main.async {
                    bridgeService.send(BridgeMessage(
                        type: "sourceIndexStatusChanged",
                        payload: payload
                    ))
                }
            }
            self.ingestService = ingestService

            let retrievalService = RetrievalService(
                persistence: persistence,
                embeddingProvider: embeddingProvider
            )
            self.retrievalService = retrievalService
            orchestrator.setRetrievalService(retrievalService)

            self.searchService = SearchService(
                persistence: persistence,
                retrieval: retrievalService
            )
        } catch {
            DebugLog.log("[WebViewManager] Failed to initialize persistence (\(DebugLog.errorSummary(error)))")
            self.persistence = nil
            self.sourceService = nil
            self.ingestService = nil
            self.autoTitleService = nil
            self.retrievalService = nil
            self.searchService = nil
        }
    }

}
