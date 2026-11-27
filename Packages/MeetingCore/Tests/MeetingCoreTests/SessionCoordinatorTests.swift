import Testing
import AVFoundation
import Foundation
import Observation
import SwiftData
@testable import MeetingCore

private let enUS = Locale(identifier: "en-US")
private let translated = SegmentStatus.translated.rawValue

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
        let container = try MeetingStorage.makeInMemoryContainer()
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
        let container = try MeetingStorage.makeInMemoryContainer()
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine, store: TranscriptStore(container: container))
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        let id = try #require(c.meetingID)
        // A volatile after a final proves the final has been handled (events are in order).
        engine.send(.finalized(text: "Kept.", range: 0...1))
        engine.send(.volatile(text: "m1"))
        await waitUntil { c.volatileText == "m1" }

        // A context of its own: the store's is `container.mainContext`.
        let other = ModelContext(container)
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

    // MARK: - Wrap-up drains the audio tail (F3) and reports late engine errors (F5)

    /// F3: buffers the source captured before `stop()` (some just before `finish()`, and a
    /// tail it only delivers inside `stop()`) all reach the engine; none is dropped.
    @MainActor @Test func audioTailCapturedBeforeStopReachesTheEngine() async throws {
        let tail = 500
        let audio = FakeAudioSource(tailOnStop: tail)
        let engine = ManualASREngine()
        let (c, _) = try makeCoordinator(engine: engine, audio: audio)
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        for _ in 0..<10 { audio.emit(makeFreshBuffer()) }
        engine.send(.volatile(text: "mid"))
        await waitUntil { c.volatileText == "mid" }
        for _ in 0..<10 { audio.emit(makeFreshBuffer()) }   // captured just before finish()
        await c.finish()
        #expect(c.state == .idle)
        #expect(audio.stopCallCount == 1)
        #expect(engine.receivedBufferCount == 20 + tail)
    }

    /// F3 fallback: a source whose `stop()` does not finish its stream still lets `finish()`
    /// complete, after the (shortened) bounded drain wait.
    @MainActor @Test func finishCompletesWhenStopLeavesTheAudioOpen() async throws {
        let audio = FakeAudioSource(finishesOnStop: false)
        let engine = ManualASREngine()
        let (c, store) = try makeCoordinator(engine: engine, audio: audio)
        c.audioDrainTimeout = .milliseconds(100)
        await c.start(locale: enUS)
        engine.send(.finalized(text: "Done.", range: 0...1))
        let began = ContinuousClock.now
        await c.finish()
        let elapsed = ContinuousClock.now - began
        #expect(c.state == .idle)
        #expect(elapsed >= .milliseconds(100))   // it really waited for the source first
        #expect(elapsed < .milliseconds(1500))
        #expect(try store.segments(of: try #require(c.meetingID)).map(\.sourceText) == ["Done."])
    }

    /// F5: the engine throws while draining after `finish()` began.
    @MainActor @Test func engineErrorAfterFinishBeganIsReported() async throws {
        let engine = FakeASREngine(events: [.finalized(text: "We start Monday.", range: 0...2)],
                                   error: FakeError.asr, keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        await c.finish()
        #expect(isFailed(c.state))
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["We start Monday."])
        #expect(segments.map(\.statusRaw) == [translated])
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    /// F5: the audio ends on its own (interruption) and the engine then throws while draining.
    @MainActor @Test func engineErrorAfterAudioEndIsReported() async throws {
        let audio = FakeAudioSource()
        let engine = FakeASREngine(events: [.finalized(text: "We start Monday.", range: 0...2)],
                                   error: FakeError.asr, keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine, audio: audio)
        await c.start(locale: enUS)
        #expect(c.state == .listening)
        audio.endStream()
        await waitUntil { c.state != .listening && c.state != .finishing }
        #expect(isFailed(c.state))
        let segments = try store.segments(of: try #require(c.meetingID))
        #expect(segments.map(\.sourceText) == ["We start Monday."])
        #expect(segments.first?.meeting?.endedAt != nil)
    }

    /// F5 + R14: an engine error and a save failure end up in one combined message.
    @MainActor @Test func engineErrorAndSaveFailureAreCombined() async throws {
        let engine = FakeASREngine(events: [], error: FakeError.asr, keepOpen: true)
        let (c, store) = try makeCoordinator(engine: engine)
        await c.start(locale: enUS)
        let id = try #require(c.meetingID)
        store.failNextSaves = 1                  // endMeeting's save fails
        await c.finish()
        guard case .failed(let message) = c.state else {
            Issue.record("expected .failed, got \(c.state)")
            return
        }
        #expect(message.contains("出现错误"))
        #expect(message.contains("会议结束时间未能保存"))
        #expect(try store.segments(of: id).isEmpty)
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

// The caption page shows a meeting only under the language it was recorded in.

@MainActor @Test(.timeLimit(.minutes(1)))
func theLastMeetingIsOfferedOnlyForTheLanguageItWasRecordedIn() async throws {
    let korean = Locale(identifier: "ko-KR")
    let (c, store) = try makeCoordinator(engine: FakeASREngine(events: []))
    #expect(c.meetingID(recordedIn: enUS) == nil)

    await c.start(locale: enUS)
    await waitUntil { c.state == .idle }
    let first = try #require(c.meetingID)
    #expect(c.meetingID(recordedIn: enUS) == first)
    #expect(c.meetingID(recordedIn: korean) == nil)
    #expect(c.meetingID == first)   // hidden for the other language, not forgotten or deleted
    #expect(try store.segments(of: first).isEmpty)

    await c.start(locale: korean)
    await waitUntil { c.state == .idle }
    let second = try #require(c.meetingID)
    #expect(second != first)
    #expect(c.meetingID(recordedIn: korean) == second)
    #expect(c.meetingID(recordedIn: enUS) == nil)
}
