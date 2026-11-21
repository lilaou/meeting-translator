import AVFoundation
import Foundation
import Synchronization
@testable import MeetingCore

enum FakeError: Error, Equatable { case translation, asr }

/// Emits `events`, then finishes (throwing `error` if given). With `keepOpen`, the event
/// stream instead stays open until the audio stream it was given finishes (like a real
/// engine) or the consumer goes away.
struct FakeASREngine: ASREngine {
    let events: [ASREvent]
    let error: Error?
    let keepOpen: Bool

    init(events: [ASREvent], error: Error? = nil, keepOpen: Bool = false) {
        self.events = events
        self.error = error
        self.keepOpen = keepOpen
    }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        let events = events, error = error, keepOpen = keepOpen
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            if keepOpen {
                finishWhenAudioEnds(audio, continuation, throwing: error)
            } else {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Finishes `continuation` once `audio` ends or the event stream's consumer is gone.
func finishWhenAudioEnds(_ audio: AsyncStream<AVAudioPCMBuffer>,
                         _ continuation: AsyncThrowingStream<ASREvent, Error>.Continuation,
                         throwing error: Error? = nil) {
    let audio = AudioHandoff(stream: audio)
    let watcher = Task {
        for await _ in audio.stream {}
        continuation.finish(throwing: error)
    }
    continuation.onTermination = { _ in watcher.cancel() }
}

/// Test-only: AsyncStream of non-Sendable buffers is not Sendable. The watcher task is the
/// stream's only consumer and never touches a buffer, so moving the stream there is safe.
private struct AudioHandoff: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
}

/// A one-shot latch: `wait()` suspends until `open()` is called (returns at once afterwards).
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s in
                if s.isOpen { return true }
                s.waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

final class FakeTranslator: Translator, Sendable {
    private let failing: Set<String>
    private let delay: Duration
    private let gate: Gate?
    private let gateUsed = Mutex(false)
    private let sizes = Mutex<[Int]>([])
    private let batchCtx = Mutex<[[String]]>([])
    private let singleCtx = Mutex<[[String]]>([])

    /// With a `gate`, the FIRST request (batch or single) blocks until the gate is opened,
    /// so a test can enqueue more work while that request is deterministically in flight.
    init(failing: Set<String> = [], delay: Duration = .zero, gate: Gate? = nil) {
        self.failing = failing
        self.delay = delay
        self.gate = gate
    }

    private func waitForGateIfFirst() async {
        guard let gate else { return }
        let isFirst = gateUsed.withLock { used in
            defer { used = true }
            return !used
        }
        if isFirst { await gate.wait() }
    }

    /// Size of every translateBatch call, in call order.
    var batchSizes: [Int] { sizes.withLock { $0 } }
    /// `context` received by every translateBatch call, in call order.
    var contexts: [[String]] { batchCtx.withLock { $0 } }
    /// `context` received by every direct (non-batch) translate call, in call order.
    var singleContexts: [[String]] { singleCtx.withLock { $0 } }

    func canTranslate(from source: Locale.Language) async -> Bool { true }

    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        singleCtx.withLock { $0.append(context) }
        await waitForGateIfFirst()
        return try await translateOne(text)
    }

    /// Throws without translating anything when any text in the batch is in `failing`.
    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String] {
        sizes.withLock { $0.append(texts.count) }
        batchCtx.withLock { $0.append(context) }
        await waitForGateIfFirst()
        if texts.contains(where: failing.contains) {
            if delay != .zero { try await Task.sleep(for: delay) }
            throw FakeError.translation
        }
        var out: [String] = []
        for t in texts { out.append(try await translateOne(t)) }
        return out
    }

    private func translateOne(_ text: String) async throws -> String {
        if delay != .zero { try await Task.sleep(for: delay) }
        if failing.contains(text) { throw FakeError.translation }
        return "译:" + text
    }
}

struct FakeReadiness: ReadinessChecking {
    let preflightError: ReadinessFailure?

    init(preflightError: ReadinessFailure? = nil) { self.preflightError = preflightError }

    func speechState(for locale: Locale) async -> PackState { .installed }
    func translationState(from source: Locale.Language) async -> PackState { .installed }
    func installSpeechPack(for locale: Locale) async throws {}
    func selfTest(locale: Locale) async throws {}
    func preflight(locale: Locale) async throws {
        if let preflightError { throw preflightError }
    }
}

/// Test-controlled audio source. `stop()` and `endStream()` both finish the stream and are
/// idempotent; `emit` after the stream finished (or before `start`) is silently dropped.
final class FakeAudioSource: AudioSource, Sendable {
    private let continuation = Mutex<AsyncStream<AVAudioPCMBuffer>.Continuation?>(nil)
    private let stops = Mutex(0)

    var stopCallCount: Int { stops.withLock { $0 } }

    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation.withLock { $0 = cont }
        return stream
    }

    func emit(_ buffer: sending AVAudioPCMBuffer) {
        let cont = continuation.withLock { $0 }
        cont?.yield(buffer)
    }

    /// Simulates a system interruption: finishes the stream.
    func endStream() {
        continuation.withLock { $0?.finish() }
    }

    func stop() async {
        stops.withLock { $0 += 1 }
        endStream()
    }
}
