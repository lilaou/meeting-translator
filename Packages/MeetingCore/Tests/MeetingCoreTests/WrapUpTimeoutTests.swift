import Testing
import Foundation
@testable import MeetingCore

private let enUS = Locale(identifier: "en-US")
private let translated = SegmentStatus.translated.rawValue
private let pending = SegmentStatus.pendingTranslation.rawValue
private let engineTimeoutHint = "识别在会议结束时未能及时完成，结尾的几句话可能没有被识别"

/// Millisecond wrap-up bounds; the pause timer is kept out of the way so a half-sentence can
/// only be flushed by wrap-up.
/// The bound a test does not exercise keeps its default, so it cannot fire on a slow machine.
private func shortBounds(engine: Duration = .seconds(10),
                         translation: Duration = .seconds(30)) -> PipelineConfig {
    var config = PipelineConfig()
    config.engineDrainTimeout = engine
    config.translationDrainTimeout = translation
    config.pauseTimeout = .seconds(3600)
    return config
}

private func failure(_ state: SessionCoordinator.State) -> String? {
    if case .failed(let message) = state { return message }
    return nil
}

/// Wrap-up bounds (task 11a-2). A regression hangs until the suite's time limit.
@Suite(.timeLimit(.minutes(1)))
struct WrapUpTimeoutTests {
    // Events: one finished sentence, a half-sentence, and a volatile that proves both finals
    // were handled before the test lets the meeting end.
    private static let events: [ASREvent] = [
        .finalized(text: "Kept. And then we", range: 0...2),
        .volatile(text: "tail"),
    ]

    @MainActor @Test func neverEndingEngineIsCutOffOnFinish() async throws {
        let engine = NeverEndingASREngine(events: Self.events)
        let (c, store) = try makeCoordinator(engine: engine,
                                             config: shortBounds(engine: .milliseconds(50)))
        await c.start(locale: enUS)
        await waitUntil { c.volatileText == "tail" }
        await c.finish()
        try expectEngineCutOff(c, store, engine)
    }

    /// The trigger is the audio source ending on its own (not `finish()`).
    @MainActor @Test func neverEndingEngineIsCutOffWhenTheAudioEnds() async throws {
        let audio = FakeAudioSource()
        let engine = NeverEndingASREngine(events: Self.events)
        let (c, store) = try makeCoordinator(engine: engine, audio: audio,
                                             config: shortBounds(engine: .milliseconds(50)))
        await c.start(locale: enUS)
        await waitUntil { c.volatileText == "tail" }
        audio.endStream()
        await waitUntil { c.state != .listening && c.state != .finishing }
        #expect(audio.stopCallCount == 1)
        try expectEngineCutOff(c, store, engine)
    }

    @MainActor private func expectEngineCutOff(_ c: SessionCoordinator, _ store: TranscriptStore,
                                               _ engine: NeverEndingASREngine) throws {
        #expect(c.state == .failed(engineTimeoutHint))
        #expect(engine.wasTerminated)            // the stream was cancelled (analyzer released)
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["Kept.", "And then we"])
        #expect(segments.map(\.translatedText) == ["译:Kept.", "译:And then we"])
        #expect(segments.allSatisfy { $0.statusRaw == translated })
        #expect(segments.first?.meeting?.endedAt != nil)
        #expect(c.volatileText.isEmpty)
        #expect(!c.isTranslationLagging)
    }

    @MainActor @Test func neverReturningTranslatorIsAbandoned() async throws {
        let gate = Gate()                        // opened only after the meeting has ended
        let engine = FakeASREngine(events: [.finalized(text: "One. Two. Three", range: 0...3)],
                                   keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, translator: FakeTranslator(gate: gate),
                                             config: shortBounds(translation: .milliseconds(50)))
        await c.start(locale: enUS)
        let queue = try #require(c.queue)
        await c.finish()
        #expect(c.state == .failed("有 3 句尚未完成翻译（原文已保存）"))
        let id = try #require(c.meetingID)
        let segments = try store.segments(of: id)
        #expect(segments.map(\.sourceText) == ["One.", "Two.", "Three"])
        #expect(segments.allSatisfy { $0.statusRaw == pending && $0.translatedText == nil })
        #expect(segments.first?.meeting?.endedAt != nil)
        #expect(!c.isTranslationLagging)

        // The abandoned request now returns; its result must be discarded.
        gate.open()
        await queue.request?.value
        let after = try store.segments(of: id)
        #expect(after.map(\.sourceText) == ["One.", "Two.", "Three"])
        #expect(after.allSatisfy { $0.statusRaw == pending && $0.translatedText == nil })
        #expect(c.state == .failed("有 3 句尚未完成翻译（原文已保存）"))
    }

    /// Outcomes that arrived before the timeout are applied; only the rest is counted.
    @MainActor @Test func translationsThatArrivedBeforeTheTimeoutAreKept() async throws {
        let gate = Gate(), stalled = Gate()
        let engine = FakeASREngine(events: [.finalized(text: "One. Two. Three.", range: 0...3)],
                                   keepOpen: true)
        let translator = StallingTranslator(stallOn: "Two.", gate: gate, stalled: stalled)
        let (c, store) = try makeCoordinator(engine: engine, translator: translator,
                                             config: shortBounds(translation: .milliseconds(50)))
        await c.start(locale: enUS)
        let queue = try #require(c.queue)
        // "One." went out alone (the queue was idle) and its outcome was yielded before the
        // request with "Two." started, so it is waiting in the outcomes stream by now.
        await stalled.wait()
        await c.finish()
        #expect(c.state == .failed("有 2 句尚未完成翻译（原文已保存）"))
        let id = try #require(c.meetingID)
        let segments = try store.segments(of: id)
        #expect(segments.map(\.sourceText) == ["One.", "Two.", "Three."])
        #expect(segments.map(\.translatedText) == ["译:One.", nil, nil])
        #expect(segments.map(\.statusRaw) == [translated, pending, pending])
        gate.open()
        await queue.request?.value
        #expect(try store.segments(of: id).map(\.translatedText) == ["译:One.", nil, nil])
    }

    @MainActor @Test func bothTimeoutsEndInOneCombinedMessage() async throws {
        let gate = Gate()
        let engine = NeverEndingASREngine(events: [
            .finalized(text: "One. Two", range: 0...2), .volatile(text: "tail"),
        ])
        let (c, store) = try makeCoordinator(
            engine: engine, translator: FakeTranslator(gate: gate),
            config: shortBounds(engine: .milliseconds(50), translation: .milliseconds(50)))
        await c.start(locale: enUS)
        await waitUntil { c.volatileText == "tail" }
        await c.finish()
        #expect(c.state == .failed(engineTimeoutHint + "；有 2 句尚未完成翻译（原文已保存）"))
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["One.", "Two"])
        #expect(segments.allSatisfy { $0.statusRaw == pending })
        #expect(segments.first?.meeting?.endedAt != nil)
        gate.open()
    }

    /// A timeout combines with a save failure (R14) into one message.
    @MainActor @Test func timeoutAndSaveFailureAreCombined() async throws {
        let engine = NeverEndingASREngine(events: [.volatile(text: "tail")])
        let (c, store) = try makeCoordinator(engine: engine,
                                             config: shortBounds(engine: .milliseconds(50)))
        await c.start(locale: enUS)
        await waitUntil { c.volatileText == "tail" }
        store.failNextSaves = 1                  // endMeeting's save fails
        await c.finish()
        let message = try #require(failure(c.state))
        #expect(message.hasPrefix(engineTimeoutHint + "；会议结束时间未能保存："))
        #expect(message.components(separatedBy: engineTimeoutHint).count == 2)   // once only
    }

    /// The defaults are generous, and a well-behaved meeting never waits for either timer.
    @MainActor @Test func defaultBoundsDoNotDelayANormalWrapUp() async throws {
        let config = PipelineConfig()
        #expect(config.engineDrainTimeout == .seconds(10))
        #expect(config.translationDrainTimeout == .seconds(30))
        let engine = FakeASREngine(events: [.finalized(text: "Done. Half", range: 0...1)],
                                   keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, config: config)
        await c.start(locale: enUS)
        let began = ContinuousClock.now
        await c.finish()
        #expect(ContinuousClock.now - began < config.engineDrainTimeout)
        #expect(c.state == .idle)
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["Done.", "Half"])
        #expect(segments.allSatisfy { $0.statusRaw == translated })
    }
}
