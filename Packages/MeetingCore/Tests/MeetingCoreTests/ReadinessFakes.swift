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
    let error: FakeError?
    private let log = Mutex<[(sentence: String, sampleRate: Double, channels: UInt32)]>([])

    init(error: FakeError? = nil) { self.error = error }

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
