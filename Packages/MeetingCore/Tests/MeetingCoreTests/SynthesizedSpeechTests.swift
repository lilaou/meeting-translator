import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

/// Uses the system speech synthesizer, so it runs only with `RUN_DEVICE_TESTS` set (a CI
/// runner may have no voice or may never finish synthesizing).
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_DEVICE_TESTS"] != nil,
               "missing: RUN_DEVICE_TESTS is not set"))
func synthesizedSpeechYieldsAudioInTheRequestedFormat() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let stream = try await SynthesizedSpeech().speech(ReadinessLogic.spokenSentence, format: format)
    var frames: AVAudioFrameCount = 0
    for await buffer in stream {
        #expect(buffer.format == format)
        frames += buffer.frameLength
    }
    // The sentence takes well over a second to say.
    #expect(frames > 16_000)
}
