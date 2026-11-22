import AVFoundation
import Foundation

public enum ASREvent: Sendable, Equatable {
    case volatile(text: String)
    case finalized(text: String, range: ClosedRange<TimeInterval>)
}

public protocol ASREngine: Sendable {
    func supportedLocales() async -> [Locale]
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat
    /// `audio` is handed over to the engine: only the engine iterates it (single consumer),
    /// and the caller never touches the stream or its buffers again.
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error>
}
