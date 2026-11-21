import AVFoundation
import Foundation

public enum ASREvent: Sendable, Equatable {
    case volatile(text: String)
    case finalized(text: String, range: ClosedRange<TimeInterval>)
}

public protocol ASREngine: Sendable {
    func supportedLocales() async -> [Locale]
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error>
}
