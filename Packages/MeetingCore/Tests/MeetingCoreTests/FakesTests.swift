import Testing
import AVFoundation
@testable import MeetingCore

@Test func fakeEngineEmitsEventsInOrder() async throws {
    let events: [ASREvent] = [.volatile(text: "hel"), .finalized(text: "Hello.", range: 0...1)]
    let engine = FakeASREngine(events: events)
    var got: [ASREvent] = []
    for try await e in engine.transcribe(AsyncStream { $0.finish() }, locale: Locale(identifier: "en-US")) { got.append(e) }
    #expect(got == events)
}

@Test func defaultBatchTranslatesEachInOrder() async throws {
    let t = FakeTranslator()
    let out = try await t.translateBatch(["a", "b"], from: .init(identifier: "en"), context: [])
    #expect(out == ["译:a", "译:b"])
}

/// Implements only the required methods, so translateBatch uses the protocol default.
private struct DefaultOnlyTranslator: Translator {
    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        "T:" + text
    }
}

@Test func protocolDefaultBatchTranslatesEachInOrder() async throws {
    let t = DefaultOnlyTranslator()
    let src = Locale.Language(identifier: "en")
    let three = try await t.translateBatch(["a", "b", "c"], from: src, context: [])
    #expect(three == ["T:a", "T:b", "T:c"])
    #expect(three.count == 3)
    let none = try await t.translateBatch([], from: src, context: [])
    #expect(none.isEmpty)
}

@Test func fakeReadinessPreflight() async throws {
    try await FakeReadiness().preflight(locale: Locale(identifier: "en-US"))
    await #expect(throws: ReadinessFailure.translationPackMissing) {
        try await FakeReadiness(preflightError: .translationPackMissing)
            .preflight(locale: Locale(identifier: "en-US"))
    }
}

private func makeFormat() -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)! }

private func makeBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: makeFormat(), frameCapacity: frames)!
    b.frameLength = frames
    return b
}

@Test func fakeAudioSourceEmitsInOrderThenEndStreamFinishes() async throws {
    let source = FakeAudioSource()
    let stream = try await source.start(format: makeFormat())
    source.emit(makeBuffer(frames: 1))
    source.emit(makeBuffer(frames: 2))
    source.endStream()
    source.endStream()
    var lengths: [AVAudioFrameCount] = []
    for await b in stream { lengths.append(b.frameLength) }
    #expect(lengths == [1, 2])
    source.emit(makeBuffer(frames: 3)) // after finish: silently dropped
    #expect(source.stopCallCount == 0)
}

@Test func fakeAudioSourceStopFinishesStreamAndCounts() async throws {
    let source = FakeAudioSource()
    let stream = try await source.start(format: makeFormat())
    await source.stop()
    var count = 0
    for await _ in stream { count += 1 }
    #expect(count == 0)
    #expect(source.stopCallCount == 1)
    await source.stop()
    #expect(source.stopCallCount == 2)
}
