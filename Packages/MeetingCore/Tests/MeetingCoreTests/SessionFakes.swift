import AVFoundation
import Foundation
import Synchronization
@testable import MeetingCore

/// Engine driven step by step by the test: `send` yields one event to the live stream.
/// The stream finishes when the audio stream it was given ends (like a real engine).
final class ManualASREngine: ASREngine, Sendable {
    private let sink = Mutex<AsyncThrowingStream<ASREvent, Error>.Continuation?>(nil)

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            sink.withLock { $0 = continuation }
            finishWhenAudioEnds(audio, continuation)
        }
    }

    func send(_ event: ASREvent) {
        let continuation = sink.withLock { $0 }
        continuation?.yield(event)
    }

    /// Ends the live event stream with `error`.
    func fail(_ error: Error) {
        let continuation = sink.withLock { $0 }
        continuation?.finish(throwing: error)
    }
}

/// Audio source whose `start` always throws.
struct FailingAudioSource: AudioSource {
    let error: AudioCaptureError

    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        throw error
    }

    func stop() async {}
}
