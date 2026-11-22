import AVFoundation
import Foundation
import Synchronization

/// Writes synthesized buffers to a file and resumes the waiting continuation exactly once:
/// at the end of the speech, at a write error, or when `finish(throwing:)` is called
/// (cancellation, deadline). Whatever comes first decides the outcome; everything after is
/// ignored, including late buffers.
///
/// Exactly once: the outcome is recorded once, under the lock, and the continuation is
/// resumed only by whoever takes it out of the state under the same lock (`start` when the
/// outcome is already known, otherwise the call that records the outcome).
final class SpeechFileWriter: Sendable {
    private struct State {
        var file: AVAudioFile?
        var wroteAudio = false
        var continuation: CheckedContinuation<Void, Error>?
        var outcome: Result<Void, any Error>?
    }

    private let url: URL
    private let state = Mutex(State())

    init(url: URL) { self.url = url }

    /// Registers the continuation; resumes it at once if the outcome is already known.
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        state.withLock { state in
            if let outcome = state.outcome {
                continuation.resume(with: outcome)
            } else {
                state.continuation = continuation
            }
        }
    }

    /// Ends with `error` unless the outcome is already decided.
    func finish(throwing error: any Error) {
        state.withLock { Self.decide(.failure(error), in: &$0) }
    }

    /// Takes over `buffer` (the synthesizer hands each one over and never touches it again).
    func append(_ buffer: sending AVAudioBuffer) {
        let url = url
        state.withLock { state in
            // `buffer` was handed over to this call; Swift 6.1 needs the explicit hand-off
            // to pass it on, and rejects throwing calls inside this closure, hence the
            // separate function.
            nonisolated(unsafe) let handoff = buffer
            Self.append(handoff, to: url, in: &state)
        }
    }

    /// Call with the lock held.
    private static func append(_ buffer: sending AVAudioBuffer, to url: URL, in state: inout State) {
        guard state.outcome == nil else { return }
        // Any buffer that is not PCM or has no frames counts as the end, so a zero-length
        // buffer in the middle would cut the audio short; fine for one short sentence.
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            decide(state.wroteAudio ? .success(()) : .failure(SelfTestAudioError.noAudio), in: &state)
            return
        }
        do {
            if state.file == nil {
                state.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                             commonFormat: pcm.format.commonFormat,
                                             interleaved: pcm.format.isInterleaved)
            }
            try state.file?.write(from: pcm)
            state.wroteAudio = true
        } catch {
            decide(.failure(error), in: &state)
        }
    }

    /// Records the first outcome, closes the file (releasing it flushes it) and resumes the
    /// continuation if it is registered. Call with the lock held.
    private static func decide(_ outcome: Result<Void, any Error>, in state: inout State) {
        guard state.outcome == nil else { return }
        state.outcome = outcome
        state.file = nil
        state.continuation?.resume(with: outcome)
        state.continuation = nil
    }
}
