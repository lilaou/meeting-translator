import AVFoundation
import Foundation
import Synchronization
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

/// One fresh buffer in the requested format, or `error`. Records every request as
/// (sentence, sample rate, channel count).
final class FakeSelfTestAudio: SelfTestAudioProvider, Sendable {
    let error: (any Error)?
    private let log = Mutex<[(sentence: String, sampleRate: Double, channels: UInt32)]>([])

    init(error: FakeError? = nil) { self.error = error }
    /// Throws `error` (any error, e.g. `CancellationError`) from every request.
    init(throwing error: any Error) { self.error = error }

    var requests: [(sentence: String, sampleRate: Double, channels: UInt32)] { log.withLock { $0 } }

    func speech(_ sentence: String, format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let request = (sentence, format.sampleRate, format.channelCount)
        log.withLock { $0.append(request) }
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

/// Translates everything to a fixed Chinese text; records each (text, source) it got.
final class RecordingTranslator: Translator, Sendable {
    private let log = Mutex<[(text: String, source: Locale.Language)]>([])

    var calls: [(text: String, source: Locale.Language)] { log.withLock { $0 } }

    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        log.withLock { $0.append((text, source)) }
        return "会议九点开始。"
    }
}

/// Throws `error` from every `translate`.
struct ThrowingTranslator: Translator {
    let error: any Error

    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        throw error
    }
}

/// Blocks every `translate` until the calling task is cancelled, then throws
/// `CancellationError` (or `errorOnCancel`, like a framework that reports a cancellation with
/// its own error). `entered` opens when the first request arrives.
final class BlockingTranslator: Translator, Sendable {
    let entered = Gate()
    let errorOnCancel: (any Error)?

    init(errorOnCancel: (any Error)? = nil) { self.errorOnCancel = errorOnCancel }

    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        let release = Gate()
        await withTaskCancellationHandler {
            entered.open()
            await release.wait()
        } onCancel: {
            release.open()
        }
        if let errorOnCancel, Task.isCancelled { throw errorOnCancel }
        try Task.checkCancellation()
        return "会议九点开始。"
    }
}

/// An engine whose event stream yields nothing and only ends when its consumer goes away
/// (a cancelled iteration then just ends, without an error). `entered` opens when the
/// stream is created.
final class SilentASREngine: ASREngine, Sendable {
    let entered = Gate()

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        let entered = entered
        return AsyncThrowingStream { continuation in
            // Kept alive until the consumer goes away; nothing is ever yielded.
            continuation.onTermination = { [continuation] _ in _ = continuation }
            entered.open()
        }
    }
}

/// An engine whose `preferredFormat` blocks until the calling task is cancelled and then
/// throws `errorOnCancel` (a domain error, not `CancellationError`). `entered` opens on the call.
final class StallingFormatEngine: ASREngine, Sendable {
    let entered = Gate()
    let errorOnCancel: any Error

    init(errorOnCancel: any Error) { self.errorOnCancel = errorOnCancel }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        let release = Gate()
        await withTaskCancellationHandler {
            entered.open()
            await release.wait()
        } onCancel: {
            release.open()
        }
        throw errorOnCancel
    }
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
