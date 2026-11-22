import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

/// Writes `seconds` of a rising ramp (-0.9 → 0.9) at 44.1 kHz mono into a temp CAF file.
private func makeRampFile(seconds: Double) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioFileSourceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("ramp.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for i in 0..<Int(frames) { samples[i] = -0.9 + 1.8 * Float(i) / Float(frames) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

@Test func audioFileIsConvertedToTheTargetFormatInOrder() async throws {
    let url = try makeRampFile(seconds: 2)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false))

    var means: [Float] = []
    var total: AVAudioFrameCount = 0
    for await buffer in try audioBuffers(fromFile: url, format: target) {
        #expect(buffer.format == target)
        let samples = try #require(buffer.floatChannelData)[0]
        let count = Int(buffer.frameLength)
        means.append((0..<count).reduce(Float(0)) { $0 + samples[$1] } / Float(count))
        total += buffer.frameLength
    }

    #expect(means.count > 1)
    #expect(abs(Double(total) - 32_000) <= 32_000 * 0.01)
    // A rising ramp: each buffer's mean is above the previous one's, so the order is kept.
    #expect(zip(means, means.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func missingAudioFileThrows() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString).wav")
    let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    #expect(throws: (any Error).self) { _ = try audioBuffers(fromFile: url, format: target) }
}
