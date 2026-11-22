import Foundation
import Testing
@testable import MeetingCore

private let english = Locale(identifier: "en-US")

private func logic(engine: any ASREngine, translator: any Translator = FakeTranslator(),
                   audio: FakeSelfTestAudio = FakeSelfTestAudio()) -> ReadinessLogic {
    ReadinessLogic(engine: engine, translator: translator,
                   packs: FakePackStates(speech: .installed, translation: .installed), audio: audio)
}

private func logic(events: [ASREvent] = [.finalized(text: "The Meeting will start at nine", range: 0...2)],
                   engineError: FakeError? = nil,
                   translator: any Translator = FakeTranslator(),
                   audio: FakeSelfTestAudio = FakeSelfTestAudio(),
                   packs: FakePackStates = FakePackStates(speech: .installed, translation: .installed))
    -> ReadinessLogic {
    ReadinessLogic(engine: FakeASREngine(events: events, error: engineError), translator: translator,
                   packs: packs, audio: audio)
}

/// The reason of the `selfTestFailed` that `body` throws, or nil if it throws nothing.
private func failureReason(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        guard case .selfTestFailed(let reason) = error as? ReadinessFailure else {
            Issue.record("unexpected \(error)")
            return nil
        }
        return reason
    }
}

@Test func selfTestPassesWithMeetingInTheTranscriptAndAChineseTranslation() async throws {
    try await logic().selfTest(locale: english)
}

@Test func selfTestTranslatesTheFixedSentenceFromTheLocaleLanguage() async throws {
    let translator = RecordingTranslator()
    let british = Locale(identifier: "en-GB")
    try await logic(translator: translator).selfTest(locale: british)
    #expect(translator.calls.count == 1)
    #expect(translator.calls.first?.text == "The meeting will start at nine.")
    #expect(translator.calls.first?.source == british.language)
}

@Test func selfTestAsksForTheSpokenSentenceInTheEnginePreferredFormat() async throws {
    let audio = FakeSelfTestAudio()
    try await logic(audio: audio).selfTest(locale: english)
    // FakeASREngine prefers 16 kHz mono.
    #expect(audio.requests.count == 1)
    #expect(audio.requests.first?.sentence == "The meeting will start at nine tomorrow morning.")
    #expect(audio.requests.first?.sampleRate == 16_000)
    #expect(audio.requests.first?.channels == 1)
}

@Test func selfTestJoinsFinalsAndIgnoresVolatileText() async throws {
    let events: [ASREvent] = [.volatile(text: "meeting"), .finalized(text: "The meet", range: 0...1),
                              .finalized(text: "ing starts", range: 1...2)]
    let reason = await failureReason { try await logic(events: events).selfTest(locale: english) }
    #expect(reason?.contains("The meet ing starts") == true)
}

@Test func selfTestFailsWhenTheTranscriptLacksMeeting() async {
    let events: [ASREvent] = [.finalized(text: "The greeting starts at nine", range: 0...2)]
    let reason = await failureReason { try await logic(events: events).selfTest(locale: english) }
    #expect(reason?.contains("meeting") == true)
    #expect(reason?.contains("The greeting starts at nine") == true)
}

@Test func selfTestFailsWhenTheTranslationIsEmptyOrBlank() async {
    for output in ["", "  \n"] {
        let reason = await failureReason {
            try await logic(translator: StubTranslator(output: output)).selfTest(locale: english)
        }
        #expect(reason == "译文为空。")
    }
}

@Test func selfTestFailsWhenTheTranslationHasNoHanCharacter() async {
    let reason = await failureReason {
        try await logic(translator: StubTranslator(output: "La réunion")).selfTest(locale: english)
    }
    #expect(reason?.contains("没有汉字") == true)
    #expect(reason?.contains("La réunion") == true)
}

@Test func selfTestReportsAnEngineError() async {
    let reason = await failureReason { try await logic(engineError: .asr).selfTest(locale: english) }
    #expect(reason?.hasPrefix("语音识别出错：") == true)
}

@Test func selfTestReportsATranslatorError() async {
    let reason = await failureReason {
        try await logic(translator: StubTranslator(error: .translation)).selfTest(locale: english)
    }
    #expect(reason?.hasPrefix("翻译出错：") == true)
}

@Test func selfTestReportsAnAudioError() async {
    let reason = await failureReason {
        try await logic(audio: FakeSelfTestAudio(error: .asr)).selfTest(locale: english)
    }
    #expect(reason?.hasPrefix("无法生成测试语音：") == true)
}

@Test func containsHanFindsChineseCharactersOnly() {
    #expect(ReadinessLogic.containsHan("会议九点开始"))
    #expect(ReadinessLogic.containsHan("Meeting 会"))
    #expect(!ReadinessLogic.containsHan("meeting"))
    #expect(!ReadinessLogic.containsHan("かな カナ 한글"))
}

@Test(arguments: [PackState.installed, .notInstalled, .unsupported],
      [PackState.installed, .notInstalled, .unsupported])
func preflightMapsEveryCombinationOfPackStates(speech: PackState, translation: PackState) async {
    let packs = FakePackStates(speech: speech, translation: translation)
    let expected: ReadinessFailure? = speech != .installed ? .speechPackMissing
        : translation != .installed ? .translationPackMissing : nil
    do {
        try await logic(packs: packs).preflight(locale: english)
        #expect(expected == nil)
    } catch {
        #expect(error == expected)
    }
}

@Test func preflightChecksTheSpeechPackFirst() async {
    let missingBoth = FakePackStates(speech: .notInstalled, translation: .notInstalled)
    await #expect(throws: ReadinessFailure.speechPackMissing) {
        try await logic(packs: missingBoth).preflight(locale: english)
    }
    #expect(missingBoth.queries == ["speech"])

    let installed = FakePackStates(speech: .installed, translation: .installed)
    try? await logic(packs: installed).preflight(locale: english)
    #expect(installed.queries == ["speech", "translation"])
}

@Test func modelReadinessErrorsAreReadable() {
    #expect(ModelReadinessError.speechUnsupported("qaa-ZZ").localizedDescription.contains("qaa-ZZ"))
    #expect(ModelReadinessError.speechInstallFailed("disk full").localizedDescription.contains("disk full"))
}

// MARK: - Cancellation passes through (11a-R6)

/// Runs `body` and reports whether it threw `CancellationError` (anything else is recorded).
private func throwsCancellation(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        Issue.record("no error")
        return false
    } catch is CancellationError {
        return true
    } catch {
        Issue.record("expected CancellationError, got \(error)")
        return false
    }
}

@Test func selfTestLetsACancelledAudioProviderThrough() async {
    #expect(await throwsCancellation {
        try await logic(audio: FakeSelfTestAudio(throwing: CancellationError())).selfTest(locale: english)
    })
}

@Test func selfTestLetsACancelledEngineStreamThrough() async {
    #expect(await throwsCancellation {
        try await logic(engine: FakeASREngine(events: [], error: CancellationError())).selfTest(locale: english)
    })
}

@Test func selfTestLetsACancelledTranslatorThrough() async {
    #expect(await throwsCancellation {
        try await logic(translator: ThrowingTranslator(error: CancellationError())).selfTest(locale: english)
    })
}

@Test func cancellingTheTaskDuringTranslationEndsTheSelfTestWithCancellation() async {
    let translator = BlockingTranslator()
    let readiness = logic(translator: translator)
    let run = Task { try await readiness.selfTest(locale: english) }
    await translator.entered.wait()
    run.cancel()
    #expect(await throwsCancellation { try await run.value })
}

@Test func cancellingTheTaskDuringRecognitionEndsTheSelfTestWithCancellation() async {
    // The cancelled iteration just ends (no error); the partial transcript must not be judged.
    let engine = SilentASREngine()
    let readiness = logic(engine: engine)
    let run = Task { try await readiness.selfTest(locale: english) }
    await engine.entered.wait()
    run.cancel()
    #expect(await throwsCancellation { try await run.value })
}
