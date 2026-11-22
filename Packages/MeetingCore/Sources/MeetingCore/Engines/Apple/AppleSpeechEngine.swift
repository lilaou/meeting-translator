// SpeechAnalyzer / SpeechTranscriber exist from the iOS 26 / macOS 26 SDKs on, which ship
// with Swift 6.2; older toolchains (and their SDKs) compile the package without this file.
#if compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// `ASREngine` on Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber`.
/// Only locales whose speech assets are already installed are used; downloading them is the
/// readiness check's job.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleSpeechEngine: ASREngine {
    public init() {}

    public func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        let transcriber = Self.makeTranscriber(locale: try await Self.resolve(locale))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw AppleSpeechError.noCompatibleAudioFormat }
        return format
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        let (events, continuation) = AsyncThrowingStream<ASREvent, Error>.makeStream()
        // The caller hands the stream over and never iterates it itself (contract 7), so
        // moving it into the session task is an ownership transfer.
        nonisolated(unsafe) let input = audio
        let session = Task {
            do {
                try await Self.run(input, locale: locale, events: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: AppleSpeechError.wrapping(error))
            }
        }
        // Consumer gone: cancelling the session cancels the analyzer and releases everything.
        continuation.onTermination = { _ in session.cancel() }
        return events
    }

    // MARK: - Session

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    static func resolve(_ locale: Locale) async throws -> Locale {
        guard let match = installedLocale(matching: locale, in: await SpeechTranscriber.installedLocales)
        else { throw AppleSpeechError.localeNotInstalled(locale.identifier(.bcp47)) }
        return match
    }

    /// Feeds `audio` to a new analyzer and forwards its results until the input has ended
    /// and every final has been sent (or until cancelled / failed).
    private static func run(_ audio: sending AsyncStream<AVAudioPCMBuffer>, locale: Locale,
                            events: AsyncThrowingStream<ASREvent, Error>.Continuation) async throws {
        let transcriber = makeTranscriber(locale: try await resolve(locale))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputSink) = AsyncStream<AnalyzerInput>.makeStream()
        try await withTaskCancellationHandler {
            try await analyzer.start(inputSequence: inputs)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await buffer in audio { inputSink.yield(AnalyzerInput(buffer: buffer)) }
                    inputSink.finish()
                    try Task.checkCancellation()
                    // Analyzes the rest of the input; the results sequence then ends.
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                group.addTask { try await forwardResults(of: transcriber, to: events) }
                do {
                    while try await group.next() != nil {}
                } catch {
                    inputSink.finish()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            }
        } onCancel: {
            inputSink.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
    }

    private static func forwardResults(of transcriber: SpeechTranscriber,
                                       to events: AsyncThrowingStream<ASREvent, Error>.Continuation)
        async throws {
        var mapper = TranscriptEventMapper()
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            let mapped = result.isFinal
                ? mapper.finalized(text: text, start: result.range.start.seconds,
                                   end: result.range.end.seconds)
                : mapper.volatile(text: text, start: result.range.start.seconds)
            for event in mapped { events.yield(event) }
        }
    }
}
#endif
