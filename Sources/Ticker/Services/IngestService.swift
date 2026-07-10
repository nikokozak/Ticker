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
    }

    private let persistence: PersistenceService
    private let sourceService: SourceService
    private let chunkingService: ChunkingService
    private let writeIndexStatus: (UUID, SourceIndexStatus) throws -> Void
    private let stateQueue = DispatchQueue(label: "com.ticker.source-ingest")

    private var queuedSources: [SourceReference] = []
    private var queuedIds = Set<UUID>()
    private var currentSourceId: UUID?
    private var currentTask: Task<Void, Never>?

    init(
        persistence: PersistenceService,
        sourceService: SourceService,
        chunkingService: ChunkingService,
        writeIndexStatus: ((UUID, SourceIndexStatus) throws -> Void)? = nil
    ) {
        self.persistence = persistence
        self.sourceService = sourceService
        self.chunkingService = chunkingService
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
        } catch {
            DebugLog.log("IngestService: Failed to enqueue pending sources (\(DebugLog.errorSummary(error)))")
        }
    }

    func cancel(sourceId: UUID? = nil) {
        stateQueue.async {
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

            guard var source = try persistence.loadSource(id: queuedSource.id) else { return }
            guard source.indexStatus == .pending || source.indexStatus == .failed else { return }

            source.indexStatus = .indexing
            try writeIndexStatus(source.id, .indexing)
            emit(.indexing, progress: 0, force: true)

            guard source.fileType == .pdf else {
                try persistence.saveSourceChunks([], for: source.id)
                emit(persistCompletionStatus(source.id, desired: .ready))
                return
            }

            let url = try sourceService.accessFile(source)
            defer { url.stopAccessingSecurityScopedResource() }

            try Task.checkCancellation()

            guard let document = PDFDocument(url: url) else {
                throw IngestError.openFailed
            }

            if document.isLocked {
                throw IngestError.noReadableText
            }

            let chunks = try chunkingService.chunkPDF(
                document: document,
                sourceId: source.id,
                progress: { progress in
                    emit(.indexing, progress: min(0.95, max(0, progress * 0.95)))
                },
                shouldCancel: { Task.isCancelled }
            )

            try Task.checkCancellation()

            guard !chunks.isEmpty else {
                throw IngestError.noReadableText
            }

            try persistence.saveSourceChunks(chunks, for: source.id)
            emit(persistCompletionStatus(source.id, desired: .ready))
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

    private func persistCompletionStatus(_ sourceId: UUID, desired: SourceIndexStatus) -> SourceIndexStatus {
        for _ in 0..<2 {
            do {
                try writeIndexStatus(sourceId, desired)
                return desired
            } catch {
                DebugLog.log("IngestService: Failed to persist terminal status (\(DebugLog.errorSummary(error)))")
            }
        }

        do {
            try writeIndexStatus(sourceId, .failed)
        } catch {
            queueFailedStatus(sourceId)
        }
        return .failed
    }

    private func queueFailedStatus(_ sourceId: UUID) {
        stateQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            do {
                try self.writeIndexStatus(sourceId, .failed)
            } catch {
                self.queueFailedStatus(sourceId)
            }
        }
    }
}
