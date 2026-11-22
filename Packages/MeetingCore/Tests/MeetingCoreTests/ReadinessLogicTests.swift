import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MeetingCore

/// Fixed pack states; records the order in which they were asked for.
final class FakePackStates: PackStateProviding, Sendable {
    let speech: PackState
    let translation: PackState
    private let log = Mutex<[String]>([])

    init(speech: PackState, translation: PackState) {
        self.speech = speech
        self.translation = translation
    }

    var queries: [String] { log.withLock { $0 } }

    func speechState(for locale: Locale) async -> PackState {
        log.withLock { $0.append("speech") }
        return speech
    }

    func translationState(from source: Locale.Language) async -> PackState {
        log.withLock { $0.append("translation") }
        return translation
    }
}

/// One fresh buffer in the requested format, or `error`.
struct FakeSelfTestAudio: SelfTestAudioProvider {
    var error: FakeError?

    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        if let error { throw error }
        let (stream, sink) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        // A new buffer that nothing here touches again.
        nonisolated(unsafe) let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        sink.yield(buffer)
        sink.finish()
        return stream
    }
}

/// Returns `output` for every text (or throws `error`).
struct StubTranslator: Translator {
    var output = ""
    var error: FakeError?

    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        if let error { throw error }
        return output
    }
}

private let english = Locale(identifier: "en-US")

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
