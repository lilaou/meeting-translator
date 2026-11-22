import Foundation
import Synchronization

/// Identifies one capture stream, so late callbacks of an earlier stream are ignored.
struct CaptureToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

enum CaptureGateError: Error, Equatable {
    /// `reserve()` while another stream is starting or running.
    case alreadyRunning
}

/// What `CaptureStreamGate.yield` did.
enum CaptureYield: Equatable {
    /// The stream is not running (finished, or a stale token): nothing was produced.
    case dropped
    /// This many elements went into the stream.
    case yielded(Int)
    /// The producer threw; the stream is finished. Carries the readable reason.
    case failed(String)
}

/// The lifecycle of capture streams, one at a time, independent of the audio hardware:
///
/// - `reserve()` claims the next stream and fails while one is starting or running;
/// - `open` creates the stream for a still-current reservation, owning `source` (the
///   converter) from then on;
/// - `yield` runs the producer and yields its output only while that stream is running;
/// - `finish` ends it exactly once: it yields the `tail` (the converter's flush), then
///   finishes the stream. Every later call, and every call before a start, does nothing.
///
/// Producing, yielding and the tail all run under one lock, so the output keeps its order and
/// nothing is produced or yielded after the finish. The continuation is finished outside the
/// lock, so a termination handler may call back into the gate.
final class CaptureStreamGate<Element, Source>: Sendable {
    private enum Phase {
        case idle
        case starting(CaptureToken)
        case running(CaptureToken, AsyncStream<Element>.Continuation, Source)
    }

    private struct State {
        var phase = Phase.idle
        var lastID: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Claims the next stream. Throws `.alreadyRunning` while one is starting or running.
    func reserve() throws(CaptureGateError) -> CaptureToken {
        try state.withLock { (state) throws(CaptureGateError) -> CaptureToken in
            guard case .idle = state.phase else { throw .alreadyRunning }
            state.lastID += 1
            let token = CaptureToken(id: state.lastID)
            state.phase = .starting(token)
            return token
        }
    }

    /// Opens the stream of `token`; nil when the reservation was cancelled by `finish`
    /// meanwhile. `onTermination` runs once when the stream ends, for whatever reason
    /// (including the consumer going away); it may call back into the gate.
    func open(_ token: CaptureToken, source: sending Source,
              onTermination: @escaping @Sendable () -> Void) -> AsyncStream<Element>? {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        continuation.onTermination = { _ in onTermination() }
        let opened = state.withLock { state in
            // `source` was handed over (`sending`) and this closure is its only user. Swift 6.1
            // cannot see that through the capture, hence the explicit hand-off (as in
            // `SpeechFileWriter.append`).
            nonisolated(unsafe) let owned = source
            return Self.run(token, continuation, owned, in: &state)
        }
        guard opened else {
            continuation.onTermination = nil
            continuation.finish()
            return nil
        }
        return stream
    }

    /// Moves a reservation that is still current to running. Call with the lock held.
    private static func run(_ token: CaptureToken, _ continuation: AsyncStream<Element>.Continuation,
                            _ source: sending Source, in state: inout State) -> Bool {
        guard case .starting(let current) = state.phase, current == token else { return false }
        state.phase = .running(token, continuation, source)
        return true
    }

    /// Whether `token` is the stream that is starting or running.
    func isCurrent(_ token: CaptureToken) -> Bool {
        state.withLock { state in
            switch state.phase {
            case .idle: false
            case .starting(let current), .running(let current, _, _): current == token
            }
        }
    }

    /// Runs `produce` and yields its output, only while the stream of `token` is running.
    /// If `produce` throws, the stream finishes (without a tail).
    func yield(_ token: CaptureToken, _ produce: (inout Source) throws -> [Element]) -> CaptureYield {
        let (result, ended) = state.withLock { state -> (CaptureYield, AsyncStream<Element>.Continuation?) in
            guard case .running(let current, let continuation, var source) = state.phase,
                  current == token else { return (.dropped, nil) }
            do {
                let elements = try produce(&source)
                state.phase = .running(token, continuation, source)
                Self.send(elements, to: continuation)
                return (.yielded(elements.count), nil)
            } catch {
                state.phase = .idle
                return (.failed(error.localizedDescription), continuation)
            }
        }
        ended?.finish()
        return result
    }

    /// Ends the stream of `token` (or whichever is current when nil) exactly once: yields
    /// `tail`, then finishes it; cancels a reservation that is still starting. Returns the
    /// token it ended, nil when there was nothing to end.
    @discardableResult
    func finish(_ token: CaptureToken? = nil,
                tail: (inout Source) -> [Element] = { _ in [] }) -> CaptureToken? {
        let (ended, continuation) = state.withLock {
            state -> (CaptureToken?, AsyncStream<Element>.Continuation?) in
            switch state.phase {
            case .idle:
                return (nil, nil)
            case .starting(let current):
                guard token == nil || token == current else { return (nil, nil) }
                state.phase = .idle
                return (current, nil)
            case .running(let current, let continuation, var source):
                guard token == nil || token == current else { return (nil, nil) }
                state.phase = .idle
                Self.send(tail(&source), to: continuation)
                return (current, continuation)
            }
        }
        continuation?.finish()
        return ended
    }

    /// Yields `elements` in order. Call with the lock held.
    private static func send(_ elements: [Element], to continuation: AsyncStream<Element>.Continuation) {
        for element in elements {
            // Each element was just made by the producer (a new buffer) and nobody keeps it:
            // the gate never touches it after yielding it, so this hands it over.
            nonisolated(unsafe) let handoff = element
            continuation.yield(handoff)
        }
    }
}
