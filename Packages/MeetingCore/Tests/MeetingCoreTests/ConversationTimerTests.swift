import Foundation
import Testing
@testable import MeetingCore

/// The three timers that end a turn, and the two bounds on its wrap-up.
@Suite(.timeLimit(.minutes(1)))
struct ConversationTimerTests {
    @Test func theDefaultsAreTheAgreedValues() {
        let timing = ConversationTiming()
        #expect(timing.pause == .seconds(2))
        #expect(timing.pause == PipelineConfig().pauseTimeout)
        #expect(timing.silence == .seconds(8))
        #expect(timing.maximum == .seconds(60))
    }

    @MainActor @Test func theWrapUpBoundsAreThoseOfTheMeeting() {
        let s = makeConversation(engine: ManualASREngine())
        #expect(s.engineDrainTimeout == .seconds(10))
        #expect(s.translationTimeout == .seconds(30))
    }

    @MainActor @Test func aPauseEndsTheTurn() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio,
                                 timing: conversationTiming(pause: .milliseconds(50)))
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.original) == ["你好"])
        #expect(audio.stopCount == 1)
    }

    /// Six changes, 100 ms apart, outlast the 500 ms pause: each one restarts it.
    @MainActor @Test func everyChangeRestartsThePause() async throws {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine,
                                 timing: conversationTiming(pause: .milliseconds(500)))
        await s.tap(.chinese)
        var text = "", lastSent = ContinuousClock.now
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(100))    // the speaker, not a sync point
            text += "好"
            lastSent = .now
            engine.send(.volatile(text: text))
            await waitUntil { s.liveText == text || s.phase != .listening(.chinese) }
        }
        #expect(s.phase == .listening(.chinese))
        await waitUntil { s.phase == .idle }
        #expect(ContinuousClock.now - lastSent >= .milliseconds(500))
        #expect(s.utterances.map(\.original) == ["好好好好好好"])
    }

    /// The pause (20 ms) must not end a turn that has no text yet: only the silence limit does.
    @MainActor @Test func silenceWithoutTextEndsWithNotHeard() async {
        let translator = ConversationTranslator(), audio = ProbeAudioSource()
        let s = makeConversation(
            engine: ManualASREngine(), audio: audio, translator: translator,
            timing: conversationTiming(pause: .milliseconds(20), silence: .milliseconds(200)))
        let began = ContinuousClock.now
        await s.tap(.chinese)
        await waitUntil { s.phase == .idle }
        #expect(ContinuousClock.now - began >= .milliseconds(200))
        #expect(s.utterances.isEmpty)
        #expect(s.notice == .notHeard)
        #expect(translator.requests.isEmpty)
        #expect(audio.stopCount == 1)
    }

    /// Once there is text, the silence limit no longer applies: the maximum ends this turn.
    @MainActor @Test func textStopsTheSilenceTimer() async {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine, timing: conversationTiming(
            silence: .milliseconds(500), maximum: .milliseconds(1500)))
        let began = ContinuousClock.now
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        await waitUntil { s.phase == .idle }
        #expect(ContinuousClock.now - began >= .milliseconds(1500))
        #expect(s.utterances.map(\.original) == ["你好"])
    }

    @MainActor @Test func theMaximumEndsTheTurn() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio,
                                 timing: conversationTiming(maximum: .milliseconds(100)))
        await s.tap(.chinese)
        engine.send(.finalized(text: "很长", range: 0...1))
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.original) == ["很长"])
        #expect(audio.stopCount == 1)
    }

    @MainActor @Test func aRecognitionThatNeverEndsIsCutOffAndKeepsTheText() async {
        let engine = NeverEndingASREngine(events: [.volatile(text: "안녕")])
        let s = makeConversation(engine: engine)
        s.engineDrainTimeout = .milliseconds(50)
        await s.tap(.korean)
        await waitUntil { s.liveText == "안녕" }
        await s.tap(.korean)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.original) == ["안녕"])
        #expect(engine.wasTerminated)
    }

    @MainActor @Test func aRecognitionThatNeverEndsWithoutTextIsReported() async {
        let engine = NeverEndingASREngine(events: [])
        let s = makeConversation(engine: engine)
        s.engineDrainTimeout = .milliseconds(50)
        await s.tap(.korean)
        await s.tap(.korean)
        await waitUntil { s.phase == .idle }
        #expect(s.notice == .failed("识别未能及时完成"))
        #expect(s.utterances.isEmpty)
    }

    @MainActor @Test func aTranslationThatNeverReturnsCountsAsFailed() async {
        let gate = Gate()
        let engine = ManualASREngine(), translator = ConversationTranslator(gate: gate)
        let s = makeConversation(engine: engine, translator: translator)
        s.translationTimeout = .milliseconds(50)
        await s.tap(.chinese)
        engine.send(.finalized(text: "你好", range: 0...1))
        await s.tap(.chinese)
        await waitUntil { s.phase == .idle }
        let expected = [ConversationUtterance(id: 0, speaker: .chinese, original: "你好", translation: nil)]
        #expect(s.utterances == expected)
        gate.open()                                    // the late result changes nothing
        await translator.returned.wait()
        for _ in 0..<10 { await Task.yield() }
        #expect(s.utterances == expected)
    }
}
