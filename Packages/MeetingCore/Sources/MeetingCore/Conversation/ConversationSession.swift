import Foundation
import Observation

/// One translated turn of a face-to-face conversation.
public struct ConversationUtterance: Identifiable, Equatable, Sendable {
    public let id: Int
    public let speaker: ConversationSide
    /// What was recognized, in the speaker's language.
    public let original: String
    /// In the other side's language; nil when the translation failed.
    public let translation: String?
}

/// The limits that end a turn on their own.
public struct ConversationTiming: Sendable {
    /// How long the recognized text may stay unchanged, once there is any.
    public var pause: Duration = .seconds(2)
    /// How long a turn may run without any recognized text.
    public var silence: Duration = .seconds(8)
    /// The longest a turn may record.
    public var maximum: Duration = .seconds(60)
    public init() {}
}

/// The state machine of a face-to-face conversation, one spoken turn at a time:
/// `idle` → `starting` → `listening` (from here the timers run) → `finishing` (recognition
/// drain, then one translation of the whole turn) → `idle`.
///
/// A turn ends on a second tap by its side, a timer, the end of the audio stream (a system
/// interruption) or of the recognition stream. Nothing is stored; a turn that was dropped
/// (`enterBackground`, `leave`) never changes the session again.
@MainActor @Observable public final class ConversationSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting(ConversationSide)
        case listening(ConversationSide)
        case finishing(ConversationSide)
    }
    public enum Notice: Equatable, Sendable {
        /// The turn ended without any recognized text.
        case notHeard
        /// Recording or recognition failed before any text; carries a readable reason.
        case failed(String)
    }

    // `public internal(set)`: the `+Turn` extension writes these.
    public internal(set) var phase: Phase = .idle
    /// What has been recognized of the turn in progress.
    public internal(set) var liveText = ""
    public internal(set) var utterances: [ConversationUtterance] = []
    /// Why the last turn added nothing; cleared when the next one starts.
    public internal(set) var notice: Notice?

    @ObservationIgnored let engine: any ASREngine
    @ObservationIgnored let audio: any AudioSource
    @ObservationIgnored let translator: @Sendable (ConversationSide) -> any Translator
    @ObservationIgnored let timing: ConversationTiming
    /// The meeting's wrap-up bounds; internal so tests can shorten them.
    @ObservationIgnored var engineDrainTimeout = PipelineConfig().engineDrainTimeout
    @ObservationIgnored var translationTimeout = PipelineConfig().translationDrainTimeout

    /// The turn in progress; nil exactly when `phase` is `.idle`.
    @ObservationIgnored var turn: ConversationTurn?
    /// Tail of the serial chain of audio starts and stops.
    @ObservationIgnored var audioTail: Task<Void, Never>?
    @ObservationIgnored var isBackground = false
    /// Set while a finished turn waits for the foreground to translate.
    var foregroundSignal: AsyncStream<Void>.Continuation?

    /// `translator(side)` renders what `side` says into the other side's language.
    public init(engine: any ASREngine, audio: any AudioSource,
                translator: @escaping @Sendable (ConversationSide) -> any Translator,
                timing: ConversationTiming) {
        self.engine = engine
        self.audio = audio
        self.translator = translator
        self.timing = timing
    }

    /// When idle, starts a turn for `side` and returns once it records (or failed). From the
    /// speaking side while starting or listening, ends the turn. Otherwise ignored.
    public func tap(_ side: ConversationSide) async {
        switch phase {
        case .idle: await begin(side)
        case .starting(side): turn?.endRequested = true
        case .listening(side): if let turn { finish(turn) }
        case .starting, .listening, .finishing: return
        }
    }

    /// Drops a turn that is starting or listening. A finishing turn is kept: its recognition
    /// completes and its translation waits for `enterForeground()`.
    public func enterBackground() {
        isBackground = true
        switch phase {
        case .starting, .listening: discard()
        case .idle, .finishing: return
        }
    }

    public func enterForeground() {
        isBackground = false
        foregroundSignal?.finish()
        foregroundSignal = nil
    }

    /// Drops the turn in progress and clears the conversation. The microphone is off when
    /// this returns.
    public func leave() async {
        discard()
        utterances = []
        notice = nil
        await audioTail?.value
    }
}
