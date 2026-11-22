import AVFoundation
import Foundation

/// Gives the self-test its sample speech, already in the engine's audio format.
protocol SelfTestAudioProvider: Sendable {
    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer>
}

enum SelfTestAudioError: Error, Sendable, Equatable, LocalizedError {
    /// No speech synthesis voice for this language (BCP-47 identifier).
    case noVoice(String)
    /// The synthesizer finished without producing audio.
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noVoice(let language): "本机没有“\(language)”的语音合成声音。"
        case .noAudio: "语音合成没有产生音频。"
        }
    }
}

/// The default self-test audio: the sentence spoken by the system speech synthesizer
/// (no audio file ships with the app). The synthesized audio goes to a temporary file,
/// which `audioBuffers(fromFile:format:)` reads and converts to `format`; the file is
/// deleted before this returns.
///
/// Unverified without a device: that `write(_:toBufferCallback:)` always ends with an empty
/// buffer (otherwise this waits for good), and that the device has an en-US voice.
struct SynthesizedSpeech: SelfTestAudioProvider {
    var language = "en-US"

    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            throw SelfTestAudioError.noVoice(language)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        try await Self.synthesize(utterance, into: url)
        return try audioBuffers(fromFile: url, format: format)
    }

    private static func synthesize(_ utterance: AVSpeechUtterance, into url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let writer = SpeechFileWriter(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.start(continuation)
            synthesizer.write(utterance) { buffer in writer.append(buffer) }
        }
        // The synthesizer must live until its last callback.
        withExtendedLifetime(synthesizer) {}
    }
}

/// Writes the synthesizer's buffers to a file and resumes the continuation once, at the
/// empty buffer that marks the end or at the first error. The synthesizer calls back on its
/// own queue, so all state is behind a lock.
private final class SpeechFileWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL) { self.url = url }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func append(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard continuation != nil else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                // End of the utterance: closing the file (by releasing it) flushes it.
                let wroteAudio = file != nil
                file = nil
                finish(wroteAudio ? nil : SelfTestAudioError.noAudio)
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat,
                                           interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            } catch {
                file = nil
                finish(error)
            }
        }
    }

    /// Call with the lock held.
    private func finish(_ error: (any Error)?) {
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}
