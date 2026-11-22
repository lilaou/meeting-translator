import AVFoundation
import Foundation

/// Errors of `ModelReadiness.installSpeechPack(for:)`, with readable messages for the UI.
/// Plain Foundation, so it is not gated by the SDK.
public enum ModelReadinessError: Error, Sendable, Equatable, LocalizedError {
    /// The speech recognizer has no model for this locale (BCP-47 identifier).
    case speechUnsupported(String)
    /// Reserving, downloading or installing the speech model failed; carries the reason.
    case speechInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .speechUnsupported(let identifier):
            "语音识别不支持“\(identifier)”。"
        case .speechInstallFailed(let reason):
            "语音识别模型安装失败：\(reason)"
        }
    }
}

/// Where the readiness logic reads the state of the two language packs.
protocol PackStateProviding: Sendable {
    func speechState(for locale: Locale) async -> PackState
    func translationState(from source: Locale.Language) async -> PackState
}

/// The SDK-independent half of `ModelReadiness`: the preflight mapping and the self-test,
/// driven through the engine, the translator, a pack-state provider and an audio provider,
/// so it is tested locally with fakes.
struct ReadinessLogic: Sendable {
    /// What the self-test audio says.
    static let spokenSentence = "The meeting will start at nine tomorrow morning."
    /// The word the transcript must contain (ignoring case).
    static let keyword = "meeting"
    /// What the self-test translates.
    static let translatedSentence = "The meeting will start at nine."

    let engine: any ASREngine
    let translator: any Translator
    let packs: any PackStateProviding
    let audio: any SelfTestAudioProvider

    /// Both packs must be installed; the speech pack is checked first. Only reads pack
    /// states (no recognition, no translation) and throws only `ReadinessFailure`.
    func preflight(locale: Locale) async throws(ReadinessFailure) {
        guard await packs.speechState(for: locale) == .installed else { throw .speechPackMissing }
        guard await packs.translationState(from: locale.language) == .installed else {
            throw .translationPackMissing
        }
    }

    /// Recognizes the sample speech and translates the sample sentence. A `CancellationError`
    /// (from the audio provider, the engine, the translator, or the task being cancelled while
    /// recognition or translation runs, whatever error that then produced) propagates: callers treat it as "cancelled",
    /// not as a failure. Any other problem, including another error of the engine, translator
    /// or audio provider, becomes `ReadinessFailure.selfTestFailed` with a readable reason.
    func selfTest(locale: Locale) async throws {
        let transcript = try await recognizeSample(locale: locale)
        let translation: String
        do {
            translation = try await translator.translate(Self.translatedSentence,
                                                         from: locale.language, context: [])
        } catch {
            throw Self.failure("翻译出错：", error)
        }
        // A cancelled translator may still return; its result is not judged.
        try Task.checkCancellation()
        try Self.evaluate(transcript: transcript, translation: translation)
    }

    /// The pass criteria: the transcript contains "meeting" (any case); the translation is
    /// not blank and contains at least one Han character.
    static func evaluate(transcript: String, translation: String) throws(ReadinessFailure) {
        guard transcript.lowercased().contains(keyword) else {
            throw .selfTestFailed("识别结果里没有“\(keyword)”：“\(transcript)”")
        }
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .selfTestFailed("译文为空。") }
        guard containsHan(trimmed) else { throw .selfTestFailed("译文里没有汉字：“\(trimmed)”") }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isUnifiedIdeograph }
    }

    /// A cancellation when `error` is a `CancellationError` or the task was cancelled (a real
    /// framework may report a cancellation with an error of its own); otherwise
    /// `selfTestFailed(prefix + reason)`.
    private static func failure(_ prefix: String, _ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return ReadinessFailure.selfTestFailed(prefix + error.localizedDescription)
    }

    /// The final texts of recognizing the sample speech, joined with spaces.
    private func recognizeSample(locale: Locale) async throws -> String {
        let format: AVAudioFormat
        do {
            format = try await engine.preferredFormat(for: locale)
        } catch {
            throw Self.failure("语音识别出错：", error)
        }
        let speech: AsyncStream<AVAudioPCMBuffer>
        do {
            speech = try await audio.speech(Self.spokenSentence, format: format)
        } catch {
            throw Self.failure("无法生成测试语音：", error)
        }
        var finals: [String] = []
        do {
            for try await event in engine.transcribe(speech, locale: locale) {
                if case .finalized(let text, _) = event { finals.append(text) }
            }
        } catch {
            throw Self.failure("语音识别出错：", error)
        }
        // A cancelled iteration ends without an error; the partial transcript is not judged.
        try Task.checkCancellation()
        return finals.joined(separator: " ")
    }
}
