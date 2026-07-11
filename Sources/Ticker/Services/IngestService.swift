import Foundation
import PDFKit

struct SourceIndexStatusUpdate {
    let sourceId: UUID
    let status: SourceIndexStatus
    let progress: Double?
}

final class IngestService: @unchecked Sendable {
    typealias StatusHandler = (SourceIndexStatusUpdate) -> Void

    var onStatusChange: StatusHandler?

    private enum IngestError: Error {
        case noReadableText
        case openFailed
        case embeddingUnavailable
    }

    private let persistence: PersistenceService
    private let sourceService: SourceService
    private let chunkingService: ChunkingService
    private let writeIndexStatus: (UUID, SourceIndexStatus) throws -> Void
    private let embeddingProvider: EmbeddingProvider?
    private let stateQueue = DispatchQueue(label: "com.ticker.source-ingest")

    private var queuedSources: [SourceReference] = []
    private var queuedIds = Set<UUID>()
    private var currentSourceId: UUID?
    private var currentTask: Task<Void, Never>?
    private var embeddingStreamIds: [UUID] = []
    private var currentEmbeddingStreamId: UUID?
    private var embeddingTask: Task<Void, Never>?

    init(
        persistence: PersistenceService,
        sourceService: SourceService,
        chunkingService: ChunkingService,
        embeddingProvider: EmbeddingProvider? = nil,
        writeIndexStatus: ((UUID, SourceIndexStatus) throws -> Void)? = nil
    ) {
        self.persistence = persistence
        self.sourceService = sourceService
        self.chunkingService = chunkingService
        self.embeddingProvider = embeddingProvider
        self.writeIndexStatus = writeIndexStatus ?? persistence.updateSourceIndexStatus
    }

    func enqueue(source: SourceReference) {
        guard source.indexStatus == .pending || source.indexStatus == .failed else { return }

        stateQueue.async {
            guard self.currentSourceId != source.id,
                  !self.queuedIds.contains(source.id) else { return }
            self.queuedSources.append(source)
            self.queuedIds.insert(source.id)
            self.startNextIfNeeded()
        }
    }

    func enqueuePendingSources(for streamId: UUID) {
        do {
            guard let stream = try persistence.loadStream(id: streamId) else { return }
            let statuses = try persistence.loadSourceIndexStatuses(streamId: streamId)
            for var source in stream.sources {
                source.indexStatus = statuses[source.id] ?? source.indexStatus
                enqueue(source: source)
            }
            enqueueEmbeddingPass(for: streamId)
        } catch {
            DebugLog.log("IngestService: Failed to enqueue pending sources (\(DebugLog.errorSummary(error)))")
        }
    }

    func enqueueEmbeddingPass(for streamId: UUID) {
        guard embeddingProvider != nil else { return }
        stateQueue.async {
            guard self.currentEmbeddingStreamId != streamId,
                  !self.embeddingStreamIds.contains(streamId) else { return }
            self.embeddingStreamIds.append(streamId)
            self.startNextEmbeddingPassIfNeeded()
        }
    }

    func cancel(sourceId: UUID? = nil) {
        stateQueue.sync {
            if let sourceId {
                self.queuedSources.removeAll { source in
                    if source.id == sourceId {
                        self.queuedIds.remove(source.id)
                        return true
                    }
                    return false
                }
                if self.currentSourceId == sourceId {
                    self.currentTask?.cancel()
                }
            } else {
                self.queuedSources.removeAll()
                self.queuedIds.removeAll()
                self.currentTask?.cancel()
            }
        }
    }

    private func startNextIfNeeded() {
        guard currentTask == nil, !queuedSources.isEmpty else { return }

        let source = queuedSources.removeFirst()
        queuedIds.remove(source.id)
        currentSourceId = source.id

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.process(source: source)
            self.stateQueue.async {
                self.currentTask = nil
                self.currentSourceId = nil
                self.startNextIfNeeded()
            }
        }
    }

    private func process(source queuedSource: SourceReference) async {
        var lastProgressSent = Date.distantPast

        func emit(_ status: SourceIndexStatus, progress: Double? = nil, force: Bool = false) {
            if status == .indexing, progress != nil, !force {
                let now = Date()
                guard now.timeIntervalSince(lastProgressSent) >= 0.25 else { return }
                lastProgressSent = now
            } else if status == .indexing {
                lastProgressSent = Date()
            }

            onStatusChange?(SourceIndexStatusUpdate(
                sourceId: queuedSource.id,
                status: status,
                progress: progress
            ))
        }

        do {
            try Task.checkCancellation()

            guard let source = try persistence.loadSource(id: queuedSource.id) else { return }
            guard source.indexStatus == .pending || source.indexStatus == .failed else { return }

            try writeIndexStatus(source.id, .indexing)
            emit(.indexing, progress: 0, force: true)

            let chunks: [SourceChunk]
            if source.fileType == .pdf {
                let url = try sourceService.accessFile(source)
                defer { url.stopAccessingSecurityScopedResource() }

                try Task.checkCancellation()

                guard let document = PDFDocument(url: url) else {
                    throw IngestError.openFailed
                }

                if document.isLocked {
                    throw IngestError.noReadableText
                }

                let result = try chunkingService.extractAndChunkPDF(
                    document: document,
                    sourceId: source.id,
                    progress: { progress in
                        emit(.indexing, progress: min(0.95, max(0, progress * 0.95)))
                    },
                    shouldCancel: { Task.isCancelled }
                )
                try persistence.updateSourceExtraction(
                    source.id,
                    text: result.extractedText.isEmpty ? nil : result.extractedText,
                    pageCount: result.pageCount,
                    status: result.extractedText.isEmpty ? .error : .ready
                )
                chunks = result.chunks
            } else {
                chunks = chunkingService.chunkText(source.extractedText ?? "", sourceId: source.id)
            }

            try Task.checkCancellation()

            guard !chunks.isEmpty else {
                throw IngestError.noReadableText
            }

            try persistence.saveSourceChunks(chunks, for: source.id)
            emit(persistCompletionStatus(source.id, desired: .ready))
            enqueueEmbeddingPass(for: source.streamId)
        } catch is CancellationError {
            emit(persistCompletionStatus(queuedSource.id, desired: .pending))
        } catch IngestError.noReadableText {
            try? persistence.saveSourceChunks([], for: queuedSource.id)
            emit(persistCompletionStatus(queuedSource.id, desired: .failedNoText))
        } catch {
            DebugLog.log("IngestService: Failed sourceId=\(queuedSource.id) (\(DebugLog.errorSummary(error)))")
            emit(persistCompletionStatus(queuedSource.id, desired: .failed))
        }
    }

    private func startNextEmbeddingPassIfNeeded() {
        guard embeddingTask == nil, let provider = embeddingProvider,
              !embeddingStreamIds.isEmpty else { return }
        let streamId = embeddingStreamIds.removeFirst()
        currentEmbeddingStreamId = streamId
        embeddingTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await provider.prepare() else { throw IngestError.embeddingUnavailable }
                let chunks = try self.persistence.loadChunksMissingEmbeddings(
                    streamId: streamId, modelId: provider.modelId
                )
                for start in stride(from: 0, to: chunks.count, by: 32) {
                    let batch = Array(chunks[start..<min(start + 32, chunks.count)])
                    let vectors = try await provider.embed(batch.map(\.text))
                    try self.persistence.saveChunkEmbeddings(vectors, for: batch, modelId: provider.modelId)
                }
            } catch {
                DebugLog.log("IngestService: Embedding pass failed streamId=\(streamId) (\(DebugLog.errorSummary(error)))")
            }
            self.stateQueue.async {
                self.embeddingTask = nil
                self.currentEmbeddingStreamId = nil
                self.startNextEmbeddingPassIfNeeded()
            }
        }
    }

    private func persistCompletionStatus(_ sourceId: UUID, desired: SourceIndexStatus) -> SourceIndexStatus {
        let statuses: [SourceIndexStatus] = desired == .failed ? [.failed] : [desired, .failed]
        for status in statuses {
            for _ in 0..<2 {
                do {
                    try writeIndexStatus(sourceId, status)
                    return status
                } catch {
                    DebugLog.log("IngestService: Failed to persist terminal status (\(DebugLog.errorSummary(error)))")
                }
            }
        }
        return .failed
    }
}
