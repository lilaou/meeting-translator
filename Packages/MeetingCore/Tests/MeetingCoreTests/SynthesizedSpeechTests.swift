import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MeetingCore

/// Never calls back: models a synthesizer that never sends its end-of-speech buffer.
/// `started` opens once `start` has run.
final class SilentSynthesizer: SpeechSynthesizing {
    let started = Gate()
    private let stops = Mutex(0)

    var stopCount: Int { stops.withLock { $0 } }

    func start(_ sentence: String, onBuffer: @escaping @Sendable (sending AVAudioBuffer) -> Void) throws {
        started.open()
    }

    func stop() { stops.withLock { $0 += 1 } }
}

/// Sends one second of 22.05 kHz audio in four buffers, then the empty end buffer, from
/// another thread (like the system synthesizer).
struct ScriptedSynthesizer: SpeechSynthesizing {
    func start(_ sentence: String, onBuffer: @escaping @Sendable (sending AVAudioBuffer) -> Void) throws {
        DispatchQueue.global().async {
            for _ in 0..<4 { onBuffer(Self.makeBuffer(frames: 5_513)) }
            onBuffer(Self.makeBuffer(frames: 0))
        }
    }

    /// A new silent 22.05 kHz buffer holding `frames` frames.
    private static func makeBuffer(frames: AVAudioFrameCount) -> sending AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        return buffer
    }

    func stop() {}
}

private func sixteenKHz() -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
}

@Test func synthesizedSpeechConvertsTheSynthesizerAudioToTheRequestedFormat() async throws {
    let provider = SynthesizedSpeech(makeSynthesizer: { _ in ScriptedSynthesizer() })
    var frames: AVAudioFrameCount = 0
    for await buffer in try await provider.speech("The meeting", language: "en-US", format: sixteenKHz()) {
        #expect(buffer.format == sixteenKHz())
        frames += buffer.frameLength
    }
    #expect((15_900...16_100).contains(frames))
}

@Test(arguments: ["en-US", "ko-KR"])
func synthesizedSpeechMakesTheSynthesizerForTheRequestedLanguage(language: String) async throws {
    let made = Mutex<[String]>([])
    let provider = SynthesizedSpeech(makeSynthesizer: { voice in
        made.withLock { $0.append(voice) }
        return ScriptedSynthesizer()
    })
    _ = try await provider.speech("회의", language: language, format: sixteenKHz())
    #expect(made.withLock { $0 } == [language])
}

@Test(.timeLimit(.minutes(1)))
func cancellingSynthesizedSpeechEndsItAtOnceAndStopsTheSynthesizer() async throws {
    let synthesizer = SilentSynthesizer()
    let provider = SynthesizedSpeech(deadline: .seconds(3_600), makeSynthesizer: { _ in synthesizer })
    let task = Task { _ = try await provider.speech("The meeting", language: "en-US", format: sixteenKHz()) }
    await synthesizer.started.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(synthesizer.stopCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func synthesizedSpeechGivesUpAfterTheDeadline() async throws {
    let synthesizer = SilentSynthesizer()
    let provider = SynthesizedSpeech(deadline: .milliseconds(50), makeSynthesizer: { _ in synthesizer })
    await #expect(throws: SelfTestAudioError.timedOut) {
        _ = try await provider.speech("The meeting", language: "en-US", format: sixteenKHz())
    }
    #expect(synthesizer.stopCount == 1)
    #expect(SynthesizedSpeech.defaultDeadline == .seconds(15))
    #expect(SelfTestAudioError.timedOut.localizedDescription.contains("超时"))
}

/// Uses the system speech synthesizer, so it runs only with `RUN_DEVICE_TESTS` set (a CI
/// runner may have no voice).
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_DEVICE_TESTS"] != nil,
               "missing: RUN_DEVICE_TESTS is not set"))
func synthesizedSpeechYieldsAudioInTheRequestedFormat() async throws {
    let stream = try await SynthesizedSpeech().speech(SourceLanguage.english.spokenSentence,
                                                      language: "en-US", format: sixteenKHz())
    var frames: AVAudioFrameCount = 0
    for await buffer in stream {
        #expect(buffer.format == sixteenKHz())
        frames += buffer.frameLength
    }
    // The sentence takes well over a second to say.
    #expect(frames > 16_000)
}
