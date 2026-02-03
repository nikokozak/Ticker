import Foundation

/// Handles automatic block processing: live refresh, cascade updates, schema validation
final class ProcessingService {
    private let orchestrator: AIOrchestrator
    private let dependencyService: DependencyService
    private let persistence: PersistenceService

    /// Maximum concurrent refresh operations
    private let maxConcurrentRefresh = 3

    init(
        orchestrator: AIOrchestrator,
        dependencyService: DependencyService,
        persistence: PersistenceService
    ) {
        self.orchestrator = orchestrator
        self.dependencyService = dependencyService
        self.persistence = persistence
    }

    // MARK: - Stream Open Processing

    /// Process blocks when a stream is opened
    /// Refreshes blocks with refreshTrigger == .onStreamOpen
    func processStreamOpen(
        _ stream: Stream,
        onBlockRefreshStart: @escaping (UUID) -> Void,
        onBlockChunk: @escaping (UUID, String) -> Void,
        onBlockRefreshComplete: @escaping (UUID, String) -> Void,
        onBlockRefreshError: @escaping (UUID, Error) -> Void,
        onModelSelected: ((UUID, String) -> Void)? = nil
    ) async {
        // Find blocks that need refresh on stream open
        let liveBlocks = stream.cells.filter {
            $0.processingConfig?.refreshTrigger == .onStreamOpen
        }

        guard !liveBlocks.isEmpty else { return }

        DebugLog.log("[ProcessingService] Found \(liveBlocks.count) live blocks to refresh")

        // Process in batches to limit concurrency
        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0

            for block in liveBlocks {
                // Wait if we're at max concurrency
                if activeCount >= maxConcurrentRefresh {
                    await group.next()
                    activeCount -= 1
                }

                activeCount += 1
                group.addTask {
                    await self.refreshBlock(
                        block,
                        in: stream,
                        streamId: stream.id,
                        onStart: onBlockRefreshStart,
                        onChunk: onBlockChunk,
                        onComplete: onBlockRefreshComplete,
                        onError: onBlockRefreshError,
                        onModelSelected: onModelSelected
                    )
                }
            }
        }
    }

    // MARK: - Cascade Updates

    /// Process cascade updates when a block changes
    /// Refreshes blocks with refreshTrigger == .onDependencyChange that depend on the changed block
    func processCascadeUpdate(
        changedBlockId: UUID,
        in stream: Stream,
        onBlockRefreshStart: @escaping (UUID) -> Void,
        onBlockChunk: @escaping (UUID, String) -> Void,
        onBlockRefreshComplete: @escaping (UUID, String) -> Void,
        onBlockRefreshError: @escaping (UUID, Error) -> Void
    ) async {
        // Get blocks that depend on the changed block
        let dependentIds = dependencyService.getCascadeDependents(of: changedBlockId)

        // Filter to only those with onDependencyChange trigger
        let blocksToRefresh = stream.cells.filter { cell in
            dependentIds.contains(cell.id) &&
            cell.processingConfig?.refreshTrigger == .onDependencyChange
        }

        guard !blocksToRefresh.isEmpty else { return }

        DebugLog.log("[ProcessingService] Cascade update: \(blocksToRefresh.count) blocks to refresh")

        // Process sequentially to maintain order and avoid conflicts
        for block in blocksToRefresh {
            await refreshBlock(
                block,
                in: stream,
                streamId: stream.id,
                onStart: onBlockRefreshStart,
                onChunk: onBlockChunk,
                onComplete: onBlockRefreshComplete,
                onError: onBlockRefreshError
            )
        }
    }

    // MARK: - Single Block Refresh

    /// Refresh a single block's content
    private func refreshBlock(
        _ block: Cell,
        in stream: Stream,
        streamId: UUID,
        onStart: @escaping (UUID) -> Void,
        onChunk: @escaping (UUID, String) -> Void,
        onComplete: @escaping (UUID, String) -> Void,
        onError: @escaping (UUID, Error) -> Void,
        onModelSelected: ((UUID, String) -> Void)? = nil
    ) async {
        // Determine the prompt to use
        let prompt = block.originalPrompt ?? extractPromptFromContent(block.content)

        guard !prompt.isEmpty else {
            DebugLog.log("[ProcessingService] Block \(block.id) has no prompt to refresh")
            return
        }

        DebugLog.log("[ProcessingService] Refreshing block \(block.id) (promptLength=\(prompt.count))")

        // Notify start
        await MainActor.run { onStart(block.id) }

        // Build context from referenced blocks
        let context = buildReferenceContext(for: block, in: stream)

        // Build prior cells for context (excluding this block)
        let priorCells = stream.cells
            .filter { $0.order < block.order }
            .sorted { $0.order < $1.order }
            .map { cell -> [String: String] in
                ["type": cell.type.rawValue, "content": cell.content]
            }

        var accumulatedContent = ""

        await orchestrator.route(
            query: prompt,
            streamId: streamId,
            priorCells: priorCells,
            sourceContext: context,
            onChunk: { chunk in
                accumulatedContent += chunk
                Task { @MainActor in
                    onChunk(block.id, chunk)
                }
            },
            onComplete: {
                Task { @MainActor in
                    onComplete(block.id, accumulatedContent)
                }
            },
            onError: { error in
                Task { @MainActor in
                    onError(block.id, error)
                }
            },
            onModelSelected: { modelId in
                Task { @MainActor in
                    onModelSelected?(block.id, modelId)
                }
            }
        )
    }

    // MARK: - Helpers

    /// Build context string from referenced blocks
    private func buildReferenceContext(for block: Cell, in stream: Stream) -> String? {
        guard let refs = block.references, !refs.isEmpty else { return nil }

        let refContents = refs.compactMap { refId -> String? in
            guard let refBlock = stream.cells.first(where: { $0.id == refId }) else { return nil }
            let name = refBlock.blockName ?? refBlock.id.uuidString.prefix(4).lowercased()
            let content = stripHTML(refBlock.content)
            return "[\(name)]:\n\(content)"
        }

        guard !refContents.isEmpty else { return nil }
        return "Referenced blocks:\n\n" + refContents.joined(separator: "\n\n---\n\n")
    }

    /// Extract a usable prompt from content (for blocks without originalPrompt)
    private func extractPromptFromContent(_ content: String) -> String {
        // Strip HTML and use first meaningful line
        let text = stripHTML(content).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.first ?? text
    }

    /// Strip HTML tags from content
    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }

        // Fallback: simple regex strip
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// MARK: - Processing Errors

enum ProcessingError: LocalizedError {
    case noPromptAvailable
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPromptAvailable:
            return "Block has no prompt available for refresh"
        case .refreshFailed(let reason):
            return "Refresh failed: \(reason)"
        }
    }
}
