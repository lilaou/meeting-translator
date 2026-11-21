import Testing
import Foundation
import Observation
import SwiftData
@testable import MeetingCore

private let enUS = Locale(identifier: "en-US")
private let translated = SegmentStatus.translated.rawValue

@MainActor
private func makeCoordinator(
    engine: any ASREngine, translator: FakeTranslator = FakeTranslator(),
    audio: any AudioSource = FakeAudioSource(), readiness: FakeReadiness = FakeReadiness(),
    store: TranscriptStore? = nil, config: PipelineConfig = PipelineConfig()
) throws -> (SessionCoordinator, TranscriptStore) {
    let store = try store ?? TranscriptStore.inMemory()
    let coordinator = SessionCoordinator(engine: engine, translator: translator, audio: audio,
                                         readiness: readiness, store: store, config: config)
    return (coordinator, store)
}

/// Suspends until `condition` holds, re-checking whenever an observed property changes.
@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            MainActor.assumeIsolated {
                withObservationTracking { _ = condition() } onChange: { c.resume() }
            }
        }
    }
}

/// Polls with a generous deadline. Only for waits on a real timer (the pause timeout).
@MainActor
private func poll(timeout: Duration = .seconds(2), _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return try condition()
}

private func isFailed(_ state: SessionCoordinator.State) -> Bool {
    if case .failed(let hint) = state { return !hint.isEmpty }
    return false
}

@Suite(.timeLimit(.minutes(1)))
struct SessionCoordinatorTests {
    @MainActor @Test func finalizedSentencesAreStoredAndTranslated() async throws {
        let engine = FakeASREngine(events: [
            .volatile(text: "we"),
            .finalized(text: "We start Monday.", range: 0...2),
            .finalized(text: "Thanks.", range: 2...3),
        ])
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        await waitUntil { c.state == .idle }
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["We start Monday.", "Thanks."])
        #expect(segments.map(\.translatedText) == ["译:We start Monday.", "译:Thanks."])
        #expect(segments.allSatisfy { $0.statusRaw == translated })
        #expect(c.startedAt != nil)
    }

    @MainActor @Test func volatileTextIsExposedAndClearedOnFinal() async throws {
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        engine.send(.volatile(text: "we sta"))
        await waitUntil { c.volatileText == "we sta" }
        engine.send(.finalized(text: "We start.", range: 0...1))
        await waitUntil { c.volatileText.isEmpty }
        await c.finish()
        #expect(c.state == .idle)
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["We start."])
    }

    @MainActor @Test func preflightFailureGoesToFailedWithoutMeeting() async throws {
        let audio = FakeAudioSource()
        let (c, _) = try makeCoordinator(engine: FakeASREngine(events: []), audio: audio,
                                         readiness: FakeReadiness(preflightError: .translationPackMissing))
        await c.start(locale: enUS)
        #expect(isFailed(c.state))
        #expect(c.meetingID == nil)
        #expect(c.startedAt == nil)
    }

    @MainActor @Test func audioEndingMidSentenceFlushesAndSaves() async throws {
        let audio = FakeAudioSource()
        let engine = FakeASREngine(events: [.finalized(text: "and then we need", range: 0...2)],
                                   keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, audio: audio)
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        audio.endStream()
        await waitUntil { c.state == .idle }
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["and then we need"])
        #expect(segments.first?.statusRaw == translated)
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    @MainActor @Test func engineErrorKeepsStoredSegments() async throws {
        let engine = FakeASREngine(events: [.finalized(text: "We start Monday.", range: 0...2)],
                                   error: FakeError.asr)
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        await waitUntil { isFailed(c.state) }
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["We start Monday."])
        #expect(segments.map(\.translatedText) == ["译:We start Monday."])
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    @MainActor @Test func pauseTimeoutFlushesPendingText() async throws {
        var config = PipelineConfig()
        config.pauseTimeout = .milliseconds(50)
        let engine = FakeASREngine(events: [.finalized(text: "and then we need", range: 0...2)],
                                   keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, config: config)
        await c.start(locale: enUS)
        let id = try #require(c.meetingID)
        let flushed = try await poll { try store.segments(of: id).count == 1 }
        #expect(flushed)
        #expect(c.state == .listening)   // flushed by the timer, not by wrap-up
        #expect(try store.segments(of: id).map(\.sourceText) == ["and then we need"])
        await c.finish()
        #expect(try store.segments(of: id).map(\.statusRaw) == [translated])
    }

    @MainActor @Test func translationFailureMarksSegmentFailed() async throws {
        let engine = FakeASREngine(events: [
            .finalized(text: "Good one. Bad one. Last one.", range: 0...3),
        ])
        let (c, store) = try makeCoordinator(engine: engine,
                                             translator: FakeTranslator(failing: ["Bad one."]))
        await c.start(locale: enUS)
        await waitUntil { c.state == .idle }
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["Good one.", "Bad one.", "Last one."])
        #expect(segments.map(\.translatedText) == ["译:Good one.", nil, "译:Last one."])
        #expect(segments.map(\.statusRaw) == [
            translated, SegmentStatus.translationFailed.rawValue, translated,
        ])
    }

    @MainActor @Test func finishDrainsQueueBeforeIdle() async throws {
        let gate = Gate()
        let audio = FakeAudioSource()
        let engine = FakeASREngine(events: [.finalized(text: "One. Two. Three", range: 0...3)],
                                   keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, translator: FakeTranslator(gate: gate),
                                             audio: audio)
        await c.start(locale: enUS)
        // Translation is held until wrap-up has begun, so finish() must wait for the drain.
        Task {
            await waitUntil { c.state == .finishing }
            gate.open()
        }
        await c.finish()
        #expect(c.state == .idle)
        #expect(audio.stopCallCount == 1)
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["One.", "Two.", "Three"])
        #expect(segments.allSatisfy { $0.statusRaw == translated })
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    // MARK: - Controller rulings (R13) and lagging

    @MainActor @Test func audioStartFailureEndsTheMeetingItCreated() async throws {
        let container = try ModelContainer(
            for: Meeting.self, Segment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let (c, _) = try makeCoordinator(engine: FakeASREngine(events: []),
                                         audio: FailingAudioSource(error: .permissionDenied),
                                         store: TranscriptStore(container: container))
        await c.start(locale: enUS)
        #expect(isFailed(c.state))
        #expect(c.meetingID == nil)
        let meetings = try ModelContext(container).fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        #expect(meetings.allSatisfy { $0.endedAt != nil })
    }

    @MainActor @Test func startIsIgnoredWhileListeningAndAllowedAfterFailure() async throws {
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        let first = try #require(c.meetingID)
        await c.start(locale: enUS)
        #expect(c.meetingID == first)
        engine.send(.finalized(text: "Hi.", range: 0...1))
        engine.fail(FakeError.asr)
        await waitUntil { isFailed(c.state) }
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        let second = try #require(c.meetingID)
        #expect(second != first)
        engine.send(.finalized(text: "Again.", range: 0...1))
        await c.finish()
        #expect(c.state == .idle)
        #expect(try store.segments(of: first).map(\.sourceText) == ["Hi."])
        #expect(try store.segments(of: second).map(\.sourceText) == ["Again."])
    }

    /// R14: a sentence whose append fails (even after one retry) is counted and surfaced as
    /// `.failed` at the end of wrap-up; the meeting carries on and earlier segments are kept.
    /// The failure is caused by re-keying the Meeting row from another context (deleting it
    /// would cascade to the earlier segment), so `store.append` throws `meetingNotFound`.
    @MainActor @Test func appendFailureIsSurfacedNotDropped() async throws {
        let container = try ModelContainer(
            for: Meeting.self, Segment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine, store: TranscriptStore(container: container))
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        let id = try #require(c.meetingID)
        // A volatile after a final proves the final has been handled (events are in order).
        engine.send(.finalized(text: "Kept.", range: 0...1))
        engine.send(.volatile(text: "m1"))
        await waitUntil { c.volatileText == "m1" }

        let other = container.mainContext
        let meeting = try #require(try other.fetch(FetchDescriptor<Meeting>()).first)
        meeting.id = UUID()
        try other.save()
        engine.send(.finalized(text: "Lost.", range: 1...2))
        engine.send(.volatile(text: "m2"))
        await waitUntil { c.volatileText == "m2" }
        #expect(c.state == .listening)          // the meeting carries on
        meeting.id = id                          // so endMeeting can succeed again
        try other.save()
        engine.send(.finalized(text: "After.", range: 2...3))

        await c.finish()                         // did not hang
        guard case .failed(let message) = c.state else {
            Issue.record("expected .failed, got \(c.state)")
            return
        }
        #expect(message.contains("1 句未能保存"))
        let segments = try store.segments(of: id)
        #expect(segments.map(\.sourceText) == ["Kept.", "After."])
        #expect(segments.map(\.statusRaw) == [translated, translated])
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    /// F1: the first `append` fails at `save()`; the retry must not leave a second copy.
    @MainActor @Test func saveFailureRetryStoresTheSentenceOnce() async throws {
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        let id = try #require(c.meetingID)
        store.failNextSaves = 1
        engine.send(.finalized(text: "Hello.", range: 0...1))
        await c.finish()
        #expect(c.state == .idle)
        let segments = try store.segments(of: id)
        #expect(segments.map(\.sourceText) == ["Hello."])
        #expect(segments.map(\.index) == [0])
        #expect(segments.map(\.statusRaw) == [translated])
    }

    /// F1: both attempts fail at `save()`; the sentence is counted, and no orphan row is
    /// written by the next successful save.
    @MainActor @Test func saveFailureOnBothAttemptsIsCountedWithoutOrphans() async throws {
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        let id = try #require(c.meetingID)
        store.failNextSaves = 2
        engine.send(.finalized(text: "Lost.", range: 0...1))
        engine.send(.volatile(text: "m1"))
        await waitUntil { c.volatileText == "m1" }
        engine.send(.finalized(text: "After.", range: 1...2))
        await c.finish()
        guard case .failed(let message) = c.state else {
            Issue.record("expected .failed, got \(c.state)")
            return
        }
        #expect(message.contains("1 句未能保存"))
        let segments = try store.segments(of: id)
        #expect(segments.map(\.sourceText) == ["After."])
        #expect(segments.map(\.index) == [0])
        #expect(segments.map(\.statusRaw) == [translated])
    }

    @MainActor @Test func translationLagIsExposedAndClears() async throws {
        var config = PipelineConfig()
        config.backlogThreshold = 1
        let gate = Gate()
        let engine = FakeASREngine(events: [.finalized(text: "One.", range: 0...1)], keepOpen: true)
        let (c, _) = try makeCoordinator(engine: engine, translator: FakeTranslator(gate: gate),
                                         config: config)
        await c.start(locale: enUS)
        await waitUntil { c.isTranslationLagging }
        gate.open()
        await waitUntil { !c.isTranslationLagging }
        #expect(c.state == .listening)
        await c.finish()
        #expect(c.state == .idle)
        #expect(!c.isTranslationLagging)
    }
}
