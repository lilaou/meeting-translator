import Foundation
import Testing
@testable import MeetingCore

/// Interruptions, background and leaving: the microphone goes off, nothing late reappears.
@Suite(.timeLimit(.minutes(1)))
struct ConversationInterruptionTests {
    @MainActor @Test func tapsWhileStartingNeverStartASecondRecording() async {
        let gate = Gate(), audio = ProbeAudioSource(startGate: gate)
        let s = makeConversation(engine: ManualASREngine(), audio: audio)
        let first = Task { await s.tap(.chinese) }
        await audio.entered.wait()
        #expect(s.phase == .starting(.chinese))
        await s.tap(.korean)                            // ignored
        #expect(s.phase == .starting(.chinese))
        await s.tap(.chinese)                           // remembered as "end"
        gate.open()
        await first.value
        await waitUntil { s.phase == .idle }
        #expect(audio.startCount == 1 && audio.stopCount == 1)
        #expect(!audio.isRecording)
        #expect(s.notice == .notHeard)
    }

    @MainActor @Test func anEndedAudioStreamFinishesTheTurn() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio)
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        audio.endStream()
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.translation) == ["译:你好"])
    }

    @MainActor @Test func backgroundWhileListeningDropsTheTurn() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource(), translator = ConversationTranslator()
        let s = makeConversation(engine: engine, audio: audio, translator: translator)
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        await waitUntil { s.liveText == "你好" }
        s.enterBackground()
        #expect(s.phase == .idle)
        #expect(s.liveText.isEmpty)
        s.enterForeground()
        await s.tap(.korean)                            // the next turn works
        #expect(s.phase == .listening(.korean))
        #expect(audio.isRecording && audio.stopCount == 1)
        await s.tap(.korean)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.isEmpty)
        #expect(translator.requests.isEmpty)
    }

    @MainActor @Test func backgroundAfterTheAudioEndedDefersTheTranslationUntilForeground() async {
        let engine = HeldASREngine(), audio = ProbeAudioSource(), translator = ConversationTranslator()
        let s = makeConversation(engine: engine, audio: audio, translator: translator)
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        audio.endStream()                               // an incoming call
        await waitUntil { s.phase == .finishing(.chinese) }
        s.enterBackground()
        engine.send(.finalized(text: "你好吗", range: 0...1))   // recognition still finishes
        engine.finish()
        await waitUntil { s.foregroundSignal != nil }
        #expect(translator.requests.isEmpty)
        #expect(s.phase == .finishing(.chinese))
        s.enterForeground()
        s.enterForeground()
        await waitUntil { s.phase == .idle }
        s.enterBackground()
        s.enterForeground()
        #expect(translator.requests.map(\.text) == ["你好吗"])
        #expect(s.utterances == [.init(id: 0, speaker: .chinese, original: "你好吗", translation: "译:你好吗")])
    }

    @MainActor @Test func leaveWhileStartingTurnsTheMicrophoneOff() async {
        let gate = Gate(), audio = ProbeAudioSource(startGate: gate)
        let s = makeConversation(engine: ManualASREngine(), audio: audio)
        let first = Task { await s.tap(.chinese) }
        await audio.entered.wait()
        let leaving = Task { await s.leave() }
        await waitUntil { s.phase == .idle }
        gate.open()
        await leaving.value
        await first.value
        #expect(!audio.isRecording)
        #expect(audio.startCount == 1 && audio.stopCount == 1)
        #expect(s.phase == .idle && s.notice == nil)
    }

    @MainActor @Test func leaveBeforeTheMicrophoneIsAskedForNeverStartsIt() async {
        let gate = Gate(), engine = HeldASREngine(formatGate: gate), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio)
        let first = Task { await s.tap(.chinese) }
        await engine.formatRequested.wait()
        let leaving = Task { await s.leave() }
        await waitUntil { s.phase == .idle }
        gate.open()
        await leaving.value
        await first.value
        #expect(audio.startCount == 0)
    }

    /// A new turn begun while a dropped one is still starting waits for it: never two
    /// recordings, and the old turn's stop does not end the new one.
    @MainActor @Test func aTurnAfterADroppedStartRecordsAloneAndStaysOn() async {
        let gate = Gate(), engine = ManualASREngine(), audio = ProbeAudioSource(startGate: gate)
        let s = makeConversation(engine: engine, audio: audio)
        let first = Task { await s.tap(.chinese) }
        await audio.entered.wait()
        s.enterBackground()
        s.enterForeground()
        let second = Task { await s.tap(.korean) }
        await waitUntil { s.phase == .starting(.korean) }
        #expect(audio.startCount == 1)
        gate.open()
        await first.value
        await second.value
        #expect(s.phase == .listening(.korean))
        #expect(audio.startCount == 2 && audio.stopCount == 1)
        #expect(audio.isRecording && s.notice == nil)
        await s.leave()
        #expect(!audio.isRecording)
    }

    @MainActor @Test func aLateTranslationAfterLeaveIsDropped() async {
        let gate = Gate(), engine = ManualASREngine(), audio = ProbeAudioSource()
        let translator = ConversationTranslator(gate: gate)
        let s = makeConversation(engine: engine, audio: audio, translator: translator)
        await s.tap(.chinese)
        engine.send(.finalized(text: "你好", range: 0...1))
        await s.tap(.chinese)
        await translator.requested.wait()
        await s.leave()
        #expect(s.phase == .idle)
        gate.open()
        await translator.returned.wait()
        for _ in 0..<10 { await Task.yield() }
        #expect(s.utterances.isEmpty)
        #expect(s.liveText.isEmpty && s.notice == nil)
        #expect(!audio.isRecording)
    }

    @MainActor @Test func leaveClearsTheConversationAndADeferredTranslation() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource(), translator = ConversationTranslator()
        let s = makeConversation(engine: engine, audio: audio, translator: translator)
        await s.tap(.chinese)
        engine.send(.finalized(text: "一", range: 0...1))
        await s.tap(.chinese)
        await waitUntil { s.utterances.count == 1 }
        await s.tap(.chinese)
        engine.send(.finalized(text: "二", range: 0...1))
        await s.tap(.chinese)
        s.enterBackground()                             // already finishing: kept, deferred
        await waitUntil { s.foregroundSignal != nil }
        await s.leave()
        s.enterForeground()
        for _ in 0..<10 { await Task.yield() }
        #expect(s.utterances.isEmpty && s.phase == .idle)
        #expect(translator.requests.map(\.text) == ["一"])
    }
}
