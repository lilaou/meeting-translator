import AVFoundation
import Foundation
import Observation
import Synchronization
@testable import MeetingCore

@MainActor
func makeCoordinator(
    engine: any ASREngine, translator: any Translator = FakeTranslator(),
    audio: any AudioSource = FakeAudioSource(), readiness: FakeReadiness = FakeReadiness(),
    store: TranscriptStore? = nil, config: PipelineConfig = PipelineConfig()
) throws -> (SessionCoordinator, TranscriptStore) {
    let store = try store ?? TranscriptStore.inMemory()
    let coordinator = SessionCoordinator(engine: engine, translator: translator, audio: audio,
                                         readiness: readiness, store: store, config: config)
    return (coordinator, store)
}

/// Suspends until `condition` holds, re-checking whenever an observed property changes.
@MainActor
func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            MainActor.assumeIsolated {
                withObservationTracking { _ = condition() } onChange: { c.resume() }
            }
        }
    }
}

func isFailed(_ state: SessionCoordinator.State) -> Bool {
    if case .failed(let hint) = state { return !hint.isEmpty }
    return false
}

/// Misbehaving engine: emits `events`, then IGNORES the end of its audio input and keeps the
/// event stream open until the consumer goes away. `wasTerminated` records that the stream's
/// `onTermination` ran (where a real engine cancels its analyzer).
final class NeverEndingASREngine: ASREngine, Sendable {
    private let events: [ASREvent]
    private let terminated = Mutex(false)

    init(events: [ASREvent]) { self.events = events }

    var wasTerminated: Bool { terminated.withLock { $0 } }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        let events = events
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.onTermination = { [self] _ in terminated.withLock { $0 = true } }
        }
    }
}

/// Translates like `FakeTranslator`, except that any request containing `stallOn` waits on
/// `gate` first (a gate the test never opens stands for a translation call that never returns).
/// `stalled` is opened when such a request starts waiting.
final class StallingTranslator: Translator, Sendable {
    private let stallOn: String
    private let gate: Gate
    private let stalled: Gate

    init(stallOn: String, gate: Gate, stalled: Gate = Gate()) {
        self.stallOn = stallOn
        self.gate = gate
        self.stalled = stalled
    }

    func canTranslate(from source: Locale.Language) async -> Bool { true }

    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        try await translateBatch([text], from: source, context: context)[0]
    }

    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String] {
        if texts.contains(stallOn) {
            stalled.open()
            await gate.wait()
        }
        return texts.map { "译:" + $0 }
    }
}

/// Engine driven step by step by the test: `send` yields one event to the live stream.
/// The stream finishes when the audio stream it was given ends (like a real engine).
/// `receivedBufferCount` counts the audio buffers that reached the engine.
final class ManualASREngine: ASREngine, Sendable {
    private let sink = Mutex<AsyncThrowingStream<ASREvent, Error>.Continuation?>(nil)
    private let buffers = Mutex(0)

    var receivedBufferCount: Int { buffers.withLock { $0 } }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            sink.withLock { $0 = continuation }
            finishWhenAudioEnds(audio, continuation, onBuffer: { [self] in
                buffers.withLock { $0 += 1 }
            })
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
