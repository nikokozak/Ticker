import Foundation

struct AutoTitleState: Equatable {
    let streamId: UUID
    let title: String
    let titleLocked: Bool
    let autoTitledAt: Date?
    let autoTitledLength: Int?
}

protocol RestatementProviding {
    func restate(_ s: String) async -> String?
}

extension ProxyLLMService: RestatementProviding {
    func restate(_ s: String) async -> String? {
        await generateRestatement(for: s)
    }
}

actor AutoTitleService {
    private static let minimumInterval: TimeInterval = 120
    private static let minimumUTF16Delta = 200

    private let persistence: PersistenceService
    private let restatementProvider: RestatementProviding
    private let now: () -> Date
    private let onStreamsChanged: () async -> Void
    private var inFlight: Set<UUID> = []

    init(
        persistence: PersistenceService,
        restatementProvider: RestatementProviding,
        now: @escaping () -> Date = { Date() },
        onStreamsChanged: @escaping () async -> Void = {}
    ) {
        self.persistence = persistence
        self.restatementProvider = restatementProvider
        self.now = now
        self.onStreamsChanged = onStreamsChanged
    }

    func scheduleIfNeeded(streamId: UUID, markdown: String) async {
        guard !inFlight.contains(streamId) else { return }

        let state: AutoTitleState
        do {
            guard let loadedState = try persistence.loadAutoTitleState(streamId: streamId) else { return }
            state = loadedState
        } catch {
            DebugLog.log("[AutoTitleService] Failed to load state (\(DebugLog.errorSummary(error)))")
            return
        }

        let markdownLength = markdown.utf16.count
        guard Self.shouldSchedule(state: state, markdownLength: markdownLength, now: now()) else { return }

        inFlight.insert(streamId)
        defer { inFlight.remove(streamId) }

        let input = String(markdown.prefix(2_000))
        let generated = await restatementProvider.restate(input)
        guard let title = generated?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return
        }

        do {
            let changed = try persistence.applyAutoTitle(
                streamId: streamId,
                title: title,
                markdownLength: markdownLength,
                now: now()
            )
            if changed {
                await onStreamsChanged()
            }
        } catch {
            DebugLog.log("[AutoTitleService] Failed to apply title (\(DebugLog.errorSummary(error)))")
        }
    }

    private static func shouldSchedule(state: AutoTitleState, markdownLength: Int, now: Date) -> Bool {
        guard !state.titleLocked else { return false }

        if let autoTitledAt = state.autoTitledAt,
           now.timeIntervalSince(autoTitledAt) < minimumInterval {
            return false
        }

        if state.title.isEmpty || state.title == "Untitled" {
            return true
        }

        let previousLength = state.autoTitledLength ?? 0
        return abs(markdownLength - previousLength) >= minimumUTF16Delta
    }
}
