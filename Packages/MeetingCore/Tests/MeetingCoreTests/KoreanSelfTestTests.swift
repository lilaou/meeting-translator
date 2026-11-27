import Foundation
import Testing
@testable import MeetingCore

// The self-test follows the source language: sample sentence, keyword and translation input.

private let korean = Locale(identifier: "ko-KR")
private let koreanTranscript = "회의는 내일 아침 아홉 시에 시작합니다."

private func logic(transcript: String = koreanTranscript,
                   translator: any Translator = RecordingTranslator(),
                   audio: FakeSelfTestAudio = FakeSelfTestAudio()) -> ReadinessLogic {
    ReadinessLogic(engine: FakeASREngine(events: [.finalized(text: transcript, range: 0...2)]),
                   translator: translator,
                   packs: FakePackStates(speech: .installed, translation: .installed), audio: audio)
}

private func failureReason(_ logic: ReadinessLogic, _ locale: Locale) async -> String? {
    do {
        try await logic.selfTest(locale: locale)
        return nil
    } catch {
        guard case .selfTestFailed(let reason) = error as? ReadinessFailure else {
            Issue.record("unexpected \(error)")
            return nil
        }
        return reason
    }
}

@Test func koreanSelfTestPassesWithTheKoreanKeywordAndAChineseTranslation() async throws {
    try await logic().selfTest(locale: korean)
}

@Test func koreanSelfTestSpeaksAndTranslatesTheKoreanSamples() async throws {
    let audio = FakeSelfTestAudio()
    let translator = RecordingTranslator()
    try await logic(translator: translator, audio: audio).selfTest(locale: korean)
    #expect(audio.requests.map(\.sentence) == ["회의는 내일 아침 아홉 시에 시작합니다."])
    #expect(translator.calls.map(\.text) == ["회의는 아홉 시에 시작합니다."])
    #expect(translator.calls.first?.source == korean.language)
}

@Test func koreanSelfTestFailsWhenTheTranscriptLacksTheKoreanKeyword() async {
    // An English transcript, even with "meeting", is not a Korean pass.
    let reason = await failureReason(logic(transcript: "The meeting will start"), korean)
    #expect(reason?.contains("회의") == true)
    #expect(reason?.contains("The meeting will start") == true)
}

@Test func koreanSelfTestFailsWhenTheTranslationHasNoHanCharacter() async {
    let reason = await failureReason(logic(translator: StubTranslator(output: "회의 시작")), korean)
    #expect(reason?.contains("没有汉字") == true)
}

@Test func selfTestOfALanguageWithoutASampleFailsReadablyBeforeRunningAnything() async {
    let audio = FakeSelfTestAudio()
    let translator = RecordingTranslator()
    for identifier in ["ja-JP", ""] {
        let reason = await failureReason(logic(translator: translator, audio: audio),
                                         Locale(identifier: identifier))
        #expect(reason?.contains("暂不支持") == true)
    }
    let japanese = await failureReason(logic(), Locale(identifier: "ja-JP"))
    #expect(japanese?.contains("日语") == true)
    #expect(audio.requests.isEmpty)
    #expect(translator.calls.isEmpty)
}

/// The voice follows the sample, not the region of the locale.
@Test(arguments: [("ko-KR", "ko-KR"), ("en-US", "en-US"), ("en-GB", "en-US")])
func selfTestAsksForTheVoiceOfTheSample(locale: String, voice: String) async {
    let audio = FakeSelfTestAudio()
    // The transcript does not matter here: only the audio request is looked at.
    _ = try? await logic(audio: audio).selfTest(locale: Locale(identifier: locale))
    #expect(audio.requests.map(\.language) == [voice])
}
