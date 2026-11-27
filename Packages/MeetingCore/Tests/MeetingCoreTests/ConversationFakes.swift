import AVFoundation
import Foundation
import Synchronization
@testable import MeetingCore

/// Audio source that counts recordings. With a `startGate`, `start` is held until it opens;
/// `entered` opens when a `start` is called. A `start` while recording throws, as the
/// `AudioSource` contract allows.
final class ProbeAudioSource: AudioSource, Sendable {
    private struct State {
        var starts = 0
        var stops = 0
        var live: AsyncStream<AVAudioPCMBuffer>.Continuation?
    }
    private let state = Mutex(State())
    private let startGate: Gate?
    let entered = Gate()

    init(startGate: Gate? = nil) { self.startGate = startGate }

    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }
    var isRecording: Bool { state.withLock { $0.live != nil } }

    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        state.withLock { $0.starts += 1 }
        entered.open()
        await startGate?.wait()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        try state.withLock { state in
            guard state.live == nil else { throw AudioCaptureError.engineStartFailed("already running") }
            state.live = continuation
        }
        return stream
    }

    func stop() async {
        state.withLock { $0.stops += 1 }
        endStream()
    }

    /// Simulates a system interruption: the stream ends on its own.
    func endStream() {
        let live = state.withLock { state in
            defer { state.live = nil }
            return state.live
        }
        live?.finish()
    }
}

/// Engine whose event stream the test drives and ends itself: the end of the audio does not
/// end it. With a `formatGate`, `preferredFormat` is held until it opens.
final class HeldASREngine: ASREngine, Sendable {
    private let sink = Mutex<AsyncThrowingStream<ASREvent, Error>.Continuation?>(nil)
    private let asked = Mutex<[Locale]>([])
    private let formatGate: Gate?
    let formatRequested = Gate()

    init(formatGate: Gate? = nil) { self.formatGate = formatGate }

    /// The locale of every `transcribe` call.
    var locales: [Locale] { asked.withLock { $0 } }

    func supportedLocales() async -> [Locale] { [] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        formatRequested.open()
        await formatGate?.wait()
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        asked.withLock { $0.append(locale) }
        return AsyncThrowingStream { continuation in sink.withLock { $0 = continuation } }
    }

    func send(_ event: ASREvent) {
        let continuation = sink.withLock { $0 }
        continuation?.yield(event)
    }

    func finish() {
        let continuation = sink.withLock { $0 }
        continuation?.finish()
    }
}

/// Translates like `FakeTranslator` and records every request. With a `gate`, requests are
/// held until it opens; `requested` opens when the first one arrives.
final class ConversationTranslator: Translator, Sendable {
    struct Request: Equatable {
        let text: String
        let source: Locale.Language
        let context: [String]
    }
    private let log = Mutex<[Request]>([])
    private let sides = Mutex<[ConversationSide]>([])
    private let failing: Bool
    private let gate: Gate?
    let requested = Gate()
    let returned = Gate()

    init(failing: Bool = false, gate: Gate? = nil) {
        self.failing = failing
        self.gate = gate
    }

    var requests: [Request] { log.withLock { $0 } }
    /// The side of every translator the session asked its factory for.
    var askedSides: [ConversationSide] { sides.withLock { $0 } }
    func note(_ side: ConversationSide) { sides.withLock { $0.append(side) } }

    func canTranslate(from source: Locale.Language) async -> Bool { true }

    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        log.withLock { $0.append(Request(text: text, source: source, context: context)) }
        requested.open()
        await gate?.wait()
        defer { returned.open() }
        if failing { throw FakeError.translation }
        return "译:" + text
    }
}

/// Timers far out of the way, except the ones a test sets.
func conversationTiming(pause: Duration = .seconds(3600), silence: Duration = .seconds(3600),
                        maximum: Duration = .seconds(3600)) -> ConversationTiming {
    var timing = ConversationTiming()
    timing.pause = pause
    timing.silence = silence
    timing.maximum = maximum
    return timing
}

@MainActor
func makeConversation(engine: any ASREngine, audio: any AudioSource = ProbeAudioSource(),
                      translator: ConversationTranslator = ConversationTranslator(),
                      timing: ConversationTiming = conversationTiming()) -> ConversationSession {
    ConversationSession(engine: engine, audio: audio,
                        translator: { side in translator.note(side); return translator },
                        timing: timing)
}
