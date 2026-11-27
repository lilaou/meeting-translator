import Foundation
import Testing
@testable import MeetingCore

/// What one turn produces. A regression hangs until the suite's time limit.
@Suite(.timeLimit(.minutes(1)))
struct ConversationSessionTests {
    @MainActor @Test func aTurnShowsTheOriginalAndTheTranslation() async {
        let engine = HeldASREngine(), audio = ProbeAudioSource(), translator = ConversationTranslator()
        let s = makeConversation(engine: engine, audio: audio, translator: translator)
        await s.tap(.chinese)
        #expect(s.phase == .listening(.chinese))
        engine.send(.finalized(text: "你好", range: 0...1))
        await waitUntil { s.liveText == "你好" }
        await s.tap(.chinese)
        #expect(s.phase == .finishing(.chinese))
        engine.finish()
        await waitUntil { s.phase == .idle }
        #expect(s.utterances == [.init(id: 0, speaker: .chinese, original: "你好", translation: "译:你好")])
        #expect(s.liveText.isEmpty)
        #expect(s.notice == nil)
        #expect(audio.stopCount == 1)
        #expect(engine.locales == [ConversationSide.chinese.speechLocale])
        #expect(translator.askedSides == [.chinese])
        #expect(translator.requests == [.init(
            text: "你好", source: ConversationSide.chinese.translationLanguage, context: [])])
    }

    @MainActor @Test func theKoreanSideUsesItsOwnLanguagesAndIdsCount() async {
        let engine = ManualASREngine(), translator = ConversationTranslator()
        let s = makeConversation(engine: engine, translator: translator)
        for (side, text) in [(ConversationSide.chinese, "你好"), (.korean, "안녕")] {
            await s.tap(side)
            engine.send(.finalized(text: text, range: 0...1))
            await s.tap(side)
            await waitUntil { s.phase == .idle }
        }
        #expect(s.utterances.map(\.id) == [0, 1])
        #expect(s.utterances.map(\.speaker) == [.chinese, .korean])
        #expect(translator.askedSides == [.chinese, .korean])
        #expect(translator.requests.last?.source == ConversationSide.korean.translationLanguage)
    }

    @MainActor @Test func volatileOnlyTextIsKept() async {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine)
        await s.tap(.korean)
        engine.send(.volatile(text: "안녕"))
        await s.tap(.korean)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.original) == ["안녕"])
    }

    @MainActor @Test(arguments: [
        (ConversationSide.chinese, ["今天", "很好。"], "今天很好。"),
        (ConversationSide.korean, ["오늘은", "좋아요."], "오늘은 좋아요."),
    ])
    func piecesAreJoinedByLanguage(side: ConversationSide, pieces: [String], expected: String) async {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine)
        await s.tap(side)
        engine.send(.finalized(text: pieces[0], range: 0...1))
        engine.send(.volatile(text: pieces[1]))
        await waitUntil { s.liveText == expected }        // finals and the volatile tail
        engine.send(.finalized(text: " \(pieces[1]) ", range: 1...2))
        await s.tap(side)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.original) == [expected])
    }

    @Test func joiningTrimsAndSkipsBlankPieces() {
        #expect(ConversationText.join([" 好 ", "  ", "。", "\n"]) == "好。")
        #expect(ConversationText.join(["", " one ", "two"]) == "one two")
        #expect(ConversationText.join([]) == "")
    }

    @MainActor @Test func aFailedTranslationKeepsTheOriginal() async {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine, translator: ConversationTranslator(failing: true))
        await s.tap(.chinese)
        engine.send(.finalized(text: "你好", range: 0...1))
        await s.tap(.chinese)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances == [.init(id: 0, speaker: .chinese, original: "你好", translation: nil)])
        #expect(s.notice == nil)
    }

    @MainActor @Test func anEngineErrorKeepsWhatWasHeard() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio)
        await s.tap(.chinese)
        engine.send(.volatile(text: "你好"))
        engine.fail(FakeError.asr)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.map(\.translation) == ["译:你好"])
        #expect(s.notice == nil)
        #expect(audio.stopCount == 1 && !audio.isRecording)
    }

    @MainActor @Test func anEngineErrorWithoutTextIsReportedAndClearedByTheNextTurn() async {
        let engine = ManualASREngine()
        let s = makeConversation(engine: engine)
        await s.tap(.chinese)
        engine.fail(FakeError.asr)
        await waitUntil { s.phase == .idle }
        #expect(s.utterances.isEmpty)
        #expect(s.notice == .failed(UserMessages.hint(for: FakeError.asr)))
        await s.tap(.korean)
        #expect(s.notice == nil)
        await s.leave()
    }

    @MainActor @Test func audioStartFailureIsReported() async {
        let error = AudioCaptureError.permissionDenied
        let s = makeConversation(engine: ManualASREngine(), audio: FailingAudioSource(error: error))
        await s.tap(.chinese)
        #expect(s.phase == .idle)
        #expect(s.notice == .failed(UserMessages.hint(for: error)))
        #expect(s.utterances.isEmpty)
    }

    @MainActor @Test func theOtherSideIsIgnoredWhileListening() async {
        let engine = ManualASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio)
        await s.tap(.chinese)
        await s.tap(.korean)
        #expect(s.phase == .listening(.chinese))
        #expect(audio.startCount == 1 && audio.stopCount == 0)
        await s.leave()
    }

    @MainActor @Test func tapsWhileFinishingAreIgnored() async {
        let engine = HeldASREngine(), audio = ProbeAudioSource()
        let s = makeConversation(engine: engine, audio: audio)
        await s.tap(.chinese)
        await s.tap(.chinese)
        await s.tap(.chinese)
        await s.tap(.korean)
        #expect(s.phase == .finishing(.chinese))
        engine.finish()
        await waitUntil { s.phase == .idle }
        #expect(audio.startCount == 1)
        #expect(s.notice == .notHeard)
    }
}
