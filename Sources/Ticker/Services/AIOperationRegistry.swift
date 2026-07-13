import Foundation

final class AIOperationRegistry {
    enum State: String, Equatable {
        case queued
        case preparing
        case generating
        case saving
        case succeeded
        case failed
        case canceled

        var isTerminal: Bool {
            self == .succeeded || self == .failed || self == .canceled
        }
    }

    struct Operation: Equatable {
        let requestId: String
        let streamId: UUID
        let verb: String
        let origin: String
        var state: State
        var message: String?
    }

    var onChange: ((Operation) -> Void)?

    private(set) var operations: [String: Operation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    @discardableResult
    func begin(streamId: UUID, verb: String, origin: String) -> String {
        let requestId = UUID().uuidString
        let operation = Operation(
            requestId: requestId,
            streamId: streamId,
            verb: verb,
            origin: origin,
            state: .queued,
            message: nil
        )
        operations[requestId] = operation
        onChange?(operation)
        return requestId
    }

    func attach(_ task: Task<Void, Never>, to requestId: String) {
        guard let operation = operations[requestId], !operation.state.isTerminal else {
            task.cancel()
            return
        }
        tasks[requestId] = task
    }

    func transition(_ requestId: String, to state: State, message: String? = nil) {
        guard var operation = operations[requestId],
              canTransition(from: operation.state, to: state) else {
            return
        }

        operation.state = state
        operation.message = message
        operations[requestId] = operation
        if state.isTerminal {
            tasks[requestId] = nil
        }
        onChange?(operation)
    }

    func cancel(_ requestId: String) {
        tasks[requestId]?.cancel()
        transition(requestId, to: .canceled)
    }

    func cancelAll() {
        for requestId in operations.keys where operations[requestId]?.state.isTerminal == false {
            cancel(requestId)
        }
    }

    func isActive(_ requestId: String) -> Bool {
        operations[requestId]?.state.isTerminal == false
    }

    private func canTransition(from current: State, to next: State) -> Bool {
        guard current != next, !current.isTerminal else { return false }

        switch next {
        case .queued:
            return false
        case .preparing:
            return current == .queued
        case .generating:
            return current == .queued || current == .preparing
        case .saving:
            return current == .preparing || current == .generating
        case .succeeded:
            return current == .saving
        case .failed, .canceled:
            return true
        }
    }
}
