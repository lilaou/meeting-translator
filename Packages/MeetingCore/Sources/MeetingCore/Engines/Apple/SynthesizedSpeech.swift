import AVFoundation
import Foundation
import Synchronization

/// Gives the self-test its sample speech, already in the engine's audio format.
protocol SelfTestAudioProvider: Sendable {
    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer>
}

enum SelfTestAudioError: Error, Sendable, Equatable, LocalizedError {
    /// No speech synthesis voice for this language (BCP-47 identifier).
    case noVoice(String)
    /// The synthesizer finished without producing audio.
    case noAudio
    /// The synthesizer did not finish within the deadline.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noVoice(let language): "本机没有“\(language)”的语音合成声音。"
        case .noAudio: "语音合成没有产生音频。"
        case .timedOut: "语音合成超时，没有完成。"
        }
    }
}

/// A speech synthesizer as `SynthesizedSpeech` uses it (a seam for tests).
protocol SpeechSynthesizing: Sendable {
    /// Starts speaking `sentence`. `onBuffer` receives the audio on any thread, each buffer
    /// handed over for good; a buffer that is not PCM or has no frames marks the end.
    func start(_ sentence: String, onBuffer: @escaping @Sendable (sending AVAudioBuffer) -> Void) throws
    /// Stops at once; no more buffers need to arrive.
    func stop()
}

/// The system synthesizer, writing (not playing) the speech of one voice.
final class SystemSpeechSynthesizer: SpeechSynthesizing {
    private let language: String
    private let synthesizer = Mutex(AVSpeechSynthesizer())

    init(language: String) { self.language = language }

    func start(_ sentence: String, onBuffer: @escaping @Sendable (sending AVAudioBuffer) -> Void) throws {
        let language = language
        try synthesizer.withLock { synthesizer in
            // Made inside the lock, so they share the synthesizer's region.
            guard let voice = AVSpeechSynthesisVoice(language: language) else {
                throw SelfTestAudioError.noVoice(language)
            }
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            synthesizer.write(utterance) { buffer in
                // Each callback buffer is new; the synthesizer does not use it afterwards
                // (unverified on a device; the writer only reads it during this call anyway).
                nonisolated(unsafe) let handoff = buffer
                onBuffer(handoff)
            }
        }
    }

    func stop() {
        synthesizer.withLock { _ = $0.stopSpeaking(at: .immediate) }
    }
}

/// The default self-test audio: the sentence spoken by the system speech synthesizer
/// (no audio file ships with the app). The synthesized audio goes to a temporary file,
/// which `audioBuffers(fromFile:format:)` reads and converts to `format`; the file is
/// deleted before this returns.
///
/// Bounded: synthesis ends with an error when the calling task is cancelled
/// (`CancellationError`) or after `deadline` (`SelfTestAudioError.timedOut`, 15 s by
/// default); the synthesizer is then stopped and any late buffer is ignored. Only the
/// synthesis is bounded here: recognition and translation in `selfTest` are not (a caller
/// can cancel them). Unverified without a device: that the device has an en-US voice, that
/// the system synthesizer ends with an empty buffer on iOS (otherwise every self-test fails
/// after the deadline), that 15 s is enough there, and that it does not reuse a buffer after
/// its callback returns.
struct SynthesizedSpeech: SelfTestAudioProvider {
    static let defaultDeadline: Duration = .seconds(15)

    var deadline: Duration = Self.defaultDeadline
    var makeSynthesizer: @Sendable () -> any SpeechSynthesizing = {
        SystemSpeechSynthesizer(language: "en-US")
    }

    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await synthesize(sentence, into: url)
        return try audioBuffers(fromFile: url, format: format)
    }

    /// Returns at the end of the speech, or throws at the first of: a synthesizer or write
    /// error, cancellation, the deadline. `SpeechFileWriter` resumes the wait exactly once.
    private func synthesize(_ sentence: String, into url: URL) async throws {
        let synthesizer = makeSynthesizer()
        let writer = SpeechFileWriter(url: url)
        let deadline = deadline
        let timer = Task {
            try await Task.sleep(for: deadline)   // a cancelled timer throws and does nothing
            writer.finish(throwing: SelfTestAudioError.timedOut)
            synthesizer.stop()
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.start(continuation)
                guard !Task.isCancelled else { return }   // already resumed by the handler
                do {
                    try synthesizer.start(sentence) { buffer in writer.append(buffer) }
                } catch {
                    writer.finish(throwing: error)
                }
            }
        } onCancel: {
            writer.finish(throwing: CancellationError())
            synthesizer.stop()
        }
    }
}
