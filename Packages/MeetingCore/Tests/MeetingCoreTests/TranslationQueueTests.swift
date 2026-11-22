import Testing
import Foundation
import Synchronization
@testable import MeetingCore

private let en = Locale.Language(identifier: "en")

private func makeQueue(_ translator: FakeTranslator, threshold: Int = 5, contextSize: Int = 3) -> TranslationQueue {
    var config = PipelineConfig()
    config.backlogThreshold = threshold
    config.contextSize = contextSize
    return TranslationQueue(translator: translator, source: en, config: config)
}

private func collect<T>(_ stream: AsyncStream<T>) async -> [T] {
    var out: [T] = []
    for await x in stream { out.append(x) }
    return out
}

@Test func outcomesFollowEnqueueOrder() async {
    let queue = makeQueue(FakeTranslator())
    let ids = [UUID(), UUID(), UUID()]
    for (id, text) in zip(ids, ["a", "b", "c"]) { await queue.enqueue(segmentID: id, text: text) }
    await queue.finish()
    let got = await collect(queue.outcomes)
    #expect(got.map(\.segmentID) == ids)
    #expect(got.map(\.translation) == ["译:a", "译:b", "译:c"])
}

// The gate holds the first request in flight until the follow-up enqueues have returned,
// so batch shapes are exact regardless of scheduling (no sleeps, no translator delay).

@Test func backlogIsSentAsOneBatch() async {
    let gate = Gate()
    let translator = FakeTranslator(gate: gate)
    let queue = makeQueue(translator)
    await queue.enqueue(segmentID: UUID(), text: "s0")
    for i in 1...4 { await queue.enqueue(segmentID: UUID(), text: "s\(i)") }
    gate.open()
    await queue.finish()
    #expect(translator.batchSizes == [1, 4])
    let got = await collect(queue.outcomes)
    #expect(got.map(\.translation) == (0...4).map { "译:s\($0)" })
}

@Test func oneFailureDoesNotBlockOthers() async {
    // b and c accumulate behind the gated first request into one batch, which throws as a
    // whole; the queue must fall back to per-sentence translate with the same context.
    let gate = Gate()
    let translator = FakeTranslator(failing: ["b"], gate: gate)
    let queue = makeQueue(translator)
    let ids = [UUID(), UUID(), UUID()]
    for (id, text) in zip(ids, ["a", "b", "c"]) { await queue.enqueue(segmentID: id, text: text) }
    gate.open()
    await queue.finish()
    let got = await collect(queue.outcomes)
    #expect(got.map(\.segmentID) == ids)
    #expect(got.map(\.translation) == ["译:a", nil, "译:c"])
    #expect(translator.batchSizes == [1, 2])
    #expect(translator.contexts == [[], ["a"]])
    #expect(translator.singleContexts == [["a"], ["a"]])
}

@Test func laggingTogglesAroundThreshold() async {
    let gate = Gate()
    let queue = makeQueue(FakeTranslator(gate: gate), threshold: 2)
    for text in ["a", "b", "c", "d"] { await queue.enqueue(segmentID: UUID(), text: text) }
    gate.open()
    await queue.finish()
    #expect(await collect(queue.lagging) == [true, false])
    #expect(await collect(queue.outcomes).count == 4)
}

@Test func laggingStaysSilentBelowThreshold() async {
    let queue = makeQueue(FakeTranslator(delay: .milliseconds(30)), threshold: 5)
    for text in ["a", "b", "c", "d"] { await queue.enqueue(segmentID: UUID(), text: text) }
    await queue.finish()
    #expect(await collect(queue.lagging) == [])
}

@Test func contextCarriesPreviousSources() async {
    let translator = FakeTranslator()
    let queue = makeQueue(translator, contextSize: 2)
    var outcomes = queue.outcomes.makeAsyncIterator()
    for text in ["a", "b", "c", "d"] {
        await queue.enqueue(segmentID: UUID(), text: text)
        let outcome = await outcomes.next()
        #expect(outcome?.translation == "译:" + text)
    }
    await queue.finish()
    #expect(translator.contexts == [[], ["a"], ["a", "b"], ["b", "c"]])
}

@Test func finishWaitsForInFlightWork() async {
    let queue = makeQueue(FakeTranslator(delay: .milliseconds(30)))
    let ids = [UUID(), UUID()]
    await queue.enqueue(segmentID: ids[0], text: "a")
    await queue.enqueue(segmentID: ids[1], text: "b")
    await queue.finish()
    // Collecting after finish() terminates only because both streams were finished,
    // and it can only see what was already yielded before finish() returned.
    let got = await collect(queue.outcomes)
    #expect(got.map(\.segmentID) == ids)
    #expect(got.map(\.translation) == ["译:a", "译:b"])
    #expect(await collect(queue.lagging) == [])
}

@Test func enqueueAfterFinishIsIgnored() async {
    let translator = FakeTranslator()
    let queue = makeQueue(translator)
    await queue.finish()
    await queue.enqueue(segmentID: UUID(), text: "late")
    #expect(await collect(queue.outcomes).isEmpty)
    #expect(translator.batchSizes.isEmpty)
}

/// Returns one result too few from every batch (each one labelled so a misaligned pair
/// would be visible); `translate` works per sentence.
private final class ShortBatchTranslator: Translator, Sendable {
    private let singles = Mutex<[String]>([])
    private let batches = Mutex(0)
    var singleCalls: [String] { singles.withLock { $0 } }
    var batchCalls: Int { batches.withLock { $0 } }

    func canTranslate(from source: Locale.Language) async -> Bool { true }

    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        singles.withLock { $0.append(text) }
        return "译:" + text
    }

    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String] {
        batches.withLock { $0 += 1 }
        return texts.dropFirst().map { "批:" + $0 }
    }
}

@Test func wrongCountBatchFallsBackToPerSentence() async {
    let translator = ShortBatchTranslator()
    let queue = TranslationQueue(translator: translator, source: en, config: PipelineConfig())
    let ids = [UUID(), UUID(), UUID(), UUID()]
    let texts = ["a", "b", "c", "d"]
    for (id, text) in zip(ids, texts) { await queue.enqueue(segmentID: id, text: text) }
    await queue.finish()
    let got = await collect(queue.outcomes)
    #expect(got.map(\.segmentID) == ids)
    #expect(got.map(\.translation) == ["译:a", "译:b", "译:c", "译:d"])
    #expect(translator.singleCalls == texts)
    #expect(translator.batchCalls >= 1)
}

// MARK: - abandon() (task 11a-2)

@Test func abandonWhenIdleReturnsNothingAndEndsBothStreams() async {
    let queue = makeQueue(FakeTranslator())
    #expect(await queue.abandon() == [])
    #expect(await collect(queue.outcomes).isEmpty)
    #expect(await collect(queue.lagging) == [])
}

@Test func abandonReportsInFlightAndQueuedSentencesInEnqueueOrder() async {
    let gate = Gate()                            // holds "a" in flight
    let translator = FakeTranslator(gate: gate)
    let queue = makeQueue(translator, threshold: 2)
    let ids = [UUID(), UUID(), UUID()]
    for (id, text) in zip(ids, ["a", "b", "c"]) { await queue.enqueue(segmentID: id, text: text) }
    #expect(await queue.abandon() == ids)
    // Both streams are finished at once, although the request for "a" is still running.
    #expect(await collect(queue.outcomes).isEmpty)
    #expect(await collect(queue.lagging) == [true])
    #expect(await queue.abandon() == [])         // twice is safe
    await queue.finish()                         // returns at once
    await queue.enqueue(segmentID: UUID(), text: "late")   // ignored

    // The abandoned request returns now: its result is discarded, nothing else is sent.
    gate.open()
    await queue.request?.value
    #expect(translator.batchSizes == [1])
}

@Test func abandonKeepsOutcomesThatAlreadyArrived() async {
    let gate = Gate(), stalled = Gate()
    let queue = TranslationQueue(translator: StallingTranslator(stallOn: "b", gate: gate, stalled: stalled),
                                 source: en, config: PipelineConfig())
    let ids = [UUID(), UUID(), UUID()]
    await queue.enqueue(segmentID: ids[0], text: "a")
    await queue.enqueue(segmentID: ids[1], text: "b")
    await queue.enqueue(segmentID: ids[2], text: "c")
    await stalled.wait()                         // "a" got its outcome before "b" was sent
    #expect(await queue.abandon() == [ids[1], ids[2]])
    let got = await collect(queue.outcomes)
    #expect(got.map(\.segmentID) == [ids[0]])
    #expect(got.map(\.translation) == ["译:a"])
    gate.open()
    await queue.request?.value
}

@Test func abandonReleasesAWaitingFinish() async {
    let gate = Gate()
    let queue = makeQueue(FakeTranslator(gate: gate))
    await queue.enqueue(segmentID: UUID(), text: "a")
    let finishing = Task { await queue.finish() }
    let lost = await queue.abandon()
    await finishing.value                        // hangs if a waiting finish() is not released
    #expect(lost.count == 1)
    #expect(await collect(queue.outcomes).isEmpty)
    gate.open()
    await queue.request?.value
}
