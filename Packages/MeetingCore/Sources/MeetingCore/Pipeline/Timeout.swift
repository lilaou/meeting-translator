import Synchronization

/// Runs `operation` in a task of its own and waits at most `timeout` for its result.
///
/// - Returns the result as soon as the operation finishes; the timer is cancelled and the
///   call returns without waiting for it (nothing keeps running afterwards).
/// - Returns nil when `timeout` elapses first, or when the calling task is cancelled first.
///   The operation's task is then cancelled but NOT awaited: an operation that ignores
///   cancellation keeps running on its own, and its result is dropped.
func withTimeout<T: Sendable>(_ timeout: Duration,
                              operation: @escaping @Sendable () async -> T) async -> T? {
    let slot = TimeoutSlot<T>()
    let work = Task { slot.deliver(.value(await operation())) }
    let winner = await withTaskGroup(of: TimeoutSlot<T>.Outcome.self) { group in
        // Both children end promptly when cancelled, so leaving the group never waits for
        // the timer or for the operation.
        group.addTask { await slot.wait() }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return .timedOut
            } catch {
                return .cancelled
            }
        }
        let first = await group.next() ?? .cancelled
        group.cancelAll()
        return first
    }
    guard case .value(let result) = winner else {
        work.cancel()
        return nil
    }
    return result
}

/// One-shot hand-off of the operation's outcome to a single waiter. The first `deliver` wins;
/// a cancelled waiter delivers `.cancelled` to itself and returns at once.
private final class TimeoutSlot<T: Sendable>: Sendable {
    enum Outcome: Sendable {
        case value(T)
        case timedOut
        case cancelled
    }

    private enum State {
        case empty
        case waiting(CheckedContinuation<Outcome, Never>)
        case done(Outcome)
    }

    private let state = Mutex(State.empty)

    func deliver(_ outcome: Outcome) {
        let waiter: CheckedContinuation<Outcome, Never>? = state.withLock { state in
            switch state {
            case .empty:
                state = .done(outcome)
                return nil
            case .waiting(let continuation):
                state = .done(outcome)
                return continuation
            case .done:
                return nil
            }
        }
        waiter?.resume(returning: outcome)
    }

    /// Only one caller may wait (the task group's first child).
    func wait() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let ready: Outcome? = state.withLock { state in
                    switch state {
                    case .empty:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        return .cancelled        // not reachable: there is a single waiter
                    case .done(let outcome):
                        return outcome
                    }
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            deliver(.cancelled)
        }
    }
}
