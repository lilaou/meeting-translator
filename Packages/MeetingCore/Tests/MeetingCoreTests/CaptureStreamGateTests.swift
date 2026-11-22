import Foundation
import Synchronization
import Testing
@testable import MeetingCore

/// Element `Int`, source an `Int` counter: each produce call yields the next number.
private typealias CounterGate = CaptureStreamGate<Int, Int>

private final class EventLog: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var entries: [String] { lines.withLock { $0 } }
}

private func collect(_ stream: AsyncStream<Int>) async -> [Int] {
    var values: [Int] = []
    for await value in stream { values.append(value) }
    return values
}

private func opened(_ gate: CounterGate, onTermination: @escaping @Sendable () -> Void = {}) throws
    -> (CaptureToken, AsyncStream<Int>) {
    let token = try gate.reserve()
    let stream = try #require(gate.open(token, source: 0, onTermination: onTermination))
    return (token, stream)
}

@Test func yieldedElementsArriveInOrderAndStopYieldsTheTailBeforeFinishing() async throws {
    let gate = CounterGate()
    let (token, stream) = try opened(gate)
    for _ in 0..<3 {
        #expect(gate.yield(token) { counter in counter += 1; return [counter] } == .yielded(1))
    }
    #expect(gate.finish(tail: { counter in [counter + 100] }) == token)
    #expect(await collect(stream) == [1, 2, 3, 103])
}

@Test func aSecondStartWhileStartingOrRunningIsRejected() throws {
    let gate = CounterGate()
    let token = try gate.reserve()
    #expect(throws: CaptureGateError.alreadyRunning) { try gate.reserve() }
    _ = gate.open(token, source: 0, onTermination: {})
    #expect(throws: CaptureGateError.alreadyRunning) { try gate.reserve() }
    #expect(gate.isCurrent(token))
}

@Test func aNewStreamCanStartAfterTheLastOneFinished() async throws {
    let gate = CounterGate()
    let (first, firstStream) = try opened(gate)
    gate.finish(first)
    #expect(await collect(firstStream) == [])
    let (second, secondStream) = try opened(gate)
    #expect(first != second)
    #expect(gate.yield(first) { _ in [7] } == .dropped)      // a late callback of the old stream
    #expect(gate.yield(second) { _ in [8] } == .yielded(1))
    gate.finish()
    #expect(await collect(secondStream) == [8])
}

@Test func nothingIsYieldedOrProducedAfterTheFinish() async throws {
    let gate = CounterGate()
    let (token, stream) = try opened(gate)
    gate.finish(token)
    var produced = false
    #expect(gate.yield(token) { _ in produced = true; return [1] } == .dropped)
    #expect(!produced)
    #expect(await collect(stream) == [])
}

@Test func stopIsSafeBeforeStartTwiceAndAfterTheStreamEndedOnItsOwn() async throws {
    let gate = CounterGate()
    #expect(gate.finish() == nil)                            // before any start
    let (token, stream) = try opened(gate)
    #expect(gate.finish(token, tail: { _ in [1] }) == token) // ends on its own (interruption)
    var tailRuns = 0
    #expect(gate.finish(tail: { _ in tailRuns += 1; return [2] }) == nil)
    #expect(gate.finish(tail: { _ in tailRuns += 1; return [3] }) == nil)
    #expect(tailRuns == 0)
    #expect(await collect(stream) == [1])
}

@Test func stopDuringStartupCancelsTheReservation() throws {
    let gate = CounterGate()
    let token = try gate.reserve()
    #expect(gate.finish() == token)
    #expect(!gate.isCurrent(token))
    #expect(gate.open(token, source: 0, onTermination: {}) == nil)
    _ = try gate.reserve()                                   // free for the next start
}

@Test func aFailingProducerFinishesTheStreamWithItsError() async throws {
    struct Broken: Error {}
    let gate = CounterGate()
    let (token, stream) = try opened(gate)
    #expect(gate.yield(token) { _ in [1] } == .yielded(1))
    #expect(gate.yield(token) { _ in throw Broken() } == .failed(Broken().localizedDescription))
    #expect(gate.yield(token) { _ in [2] } == .dropped)
    #expect(gate.finish() == nil)
    #expect(await collect(stream) == [1])
}

@Test func theTerminationHandlerRunsOnceWhenTheStreamFinishes() async throws {
    let calls = Mutex(0)
    let gate = CounterGate()
    let (token, stream) = try opened(gate) { calls.withLock { $0 += 1 } }
    gate.finish(token)
    gate.finish(token)
    _ = await collect(stream)
    #expect(calls.withLock { $0 } == 1)
}

@Test func aConsumerThatGoesAwayEndsTheGateFromItsTerminationHandler() async throws {
    let gate = CounterGate()
    let token = try gate.reserve()
    var stream: AsyncStream<Int>? = gate.open(token, source: 0) { [gate] in gate.finish(token) }
    #expect(stream != nil)
    stream = nil                                            // dropping the stream terminates it
    #expect(!gate.isCurrent(token))
    _ = try gate.reserve()
}

@Test func racingFinishesAndYieldsFinishExactlyOnceAndNothingIsProducedAfterIt() async throws {
    for _ in 0..<50 {
        let gate = CounterGate()
        let (token, stream) = try opened(gate)
        let log = EventLog()                                 // written under the gate's lock
        let consumer = Task { await collect(stream) }

        let (yielded, finishers) = await withTaskGroup(of: (Int, Int).self) { group in
            for _ in 0..<40 {
                group.addTask {
                    let result = gate.yield(token) { counter in
                        counter += 1
                        log.append("y\(counter)")
                        return [counter]
                    }
                    return (result == .yielded(1) ? 1 : 0, 0)
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    let finished = gate.finish(token) { counter in
                        log.append("tail")
                        return [counter + 1_000]
                    }
                    return (0, finished == nil ? 0 : 1)
                }
            }
            return await group.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        }

        let received = await consumer.value
        let entries = log.entries
        #expect(finishers == 1)
        #expect(entries.last == "tail")
        #expect(entries.filter { $0 == "tail" }.count == 1)
        #expect(received.count == yielded + 1)
        #expect(Array(received.dropLast()) == (0..<yielded).map { $0 + 1 })
        #expect(received.last == yielded + 1_000)
    }
}
