import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func floatFormat(_ rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
}

/// `count` buffers of `frames` frames continuing one rising ramp (-0.9 → 0.9 over all of
/// them), the same value in every channel; like a microphone tap at the hardware format.
private func rampBuffers(_ format: AVAudioFormat, count: Int, frames: AVAudioFrameCount) -> [AVAudioPCMBuffer] {
    let total = Float(count) * Float(frames)
    return (0..<count).map { index in
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = -0.9 + 1.8 * (Float(index) * Float(frames) + Float(i)) / total
            }
        }
        return buffer
    }
}

/// Mean of each 1600-frame block of the first channel across `buffers`, in order.
private func blockMeans(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
    var samples: [Float] = []
    for buffer in buffers {
        samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return stride(from: 0, to: samples.count - 1_599, by: 1_600).map { start in
        samples[start..<start + 1_600].reduce(0, +) / 1_600
    }
}

@Test func convertedBuffersHaveExactlyTheRequestedFormatAndTheRightLength() throws {
    let input = floatFormat(48_000, channels: 2)
    let target = floatFormat(16_000, channels: 1)
    let converter = try AudioBufferConverter(from: input, to: target)
    var outputs: [AVAudioPCMBuffer] = []
    for buffer in rampBuffers(input, count: 20, frames: 4_800) { outputs += try converter.convert(buffer) }
    outputs += try converter.flush()

    #expect(!outputs.isEmpty)
    #expect(outputs.allSatisfy { $0.format == target })
    let frames = outputs.reduce(0) { $0 + Int($1.frameLength) }
    #expect(abs(frames - 32_000) <= 32, "2 s at 16 kHz, got \(frames)")
}

@Test func convertedAudioKeepsItsOrder() throws {
    let input = floatFormat(48_000, channels: 2)
    let converter = try AudioBufferConverter(from: input, to: floatFormat(16_000, channels: 1))
    var outputs: [AVAudioPCMBuffer] = []
    for buffer in rampBuffers(input, count: 20, frames: 4_800) { outputs += try converter.convert(buffer) }
    outputs += try converter.flush()

    let means = blockMeans(outputs)
    #expect(means.count >= 19)
    #expect(zip(means, means.dropFirst()).allSatisfy { $0 < $1 }, "\(means)")
}

@Test func everyOutputIsANewBufferNeverTheInputNorAnEarlierOutput() throws {
    for target in [floatFormat(48_000, channels: 2), floatFormat(16_000, channels: 1)] {
        let input = floatFormat(48_000, channels: 2)
        let converter = try AudioBufferConverter(from: input, to: target)
        let inputs = rampBuffers(input, count: 10, frames: 4_800)
        var outputs: [AVAudioPCMBuffer] = []   // kept alive, so identities are not reused
        for buffer in inputs {
            let converted = try converter.convert(buffer)
            #expect(converted.allSatisfy { $0 !== buffer })
            outputs += converted
        }
        outputs += try converter.flush()
        #expect(Set(outputs.map(ObjectIdentifier.init)).count == outputs.count)
        #expect(Set(outputs.map(ObjectIdentifier.init)).isDisjoint(with: inputs.map(ObjectIdentifier.init)))
    }
}

@Test func identicalFormatsAreCopiedSampleForSample() throws {
    let format = floatFormat(48_000, channels: 1)
    let converter = try AudioBufferConverter(from: format, to: format)
    let input = rampBuffers(format, count: 1, frames: 4_800)[0]
    let outputs = try converter.convert(input) + converter.flush()

    #expect(outputs.allSatisfy { $0 !== input && $0.format == format })
    let copied = outputs.flatMap {
        Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)))
    }
    #expect(copied == Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: 4_800)))
    input.floatChannelData![0][0] = 42           // the copy does not share the input's memory
    #expect(outputs[0].floatChannelData![0][0] != 42)
}

@Test func flushReturnsTheConvertersTail() throws {
    let input = floatFormat(48_000, channels: 1)
    let converter = try AudioBufferConverter(from: input, to: floatFormat(16_000, channels: 1))
    let converted = try converter.convert(rampBuffers(input, count: 1, frames: 4_800)[0])
    let tail = try converter.flush()

    let before = converted.reduce(0) { $0 + Int($1.frameLength) }
    let after = tail.reduce(0) { $0 + Int($1.frameLength) }
    #expect(after > 0, "the resampler holds back frames until the end of the stream")
    #expect(abs(before + after - 1_600) <= 16, "\(before) + \(after)")
    #expect(try converter.flush().isEmpty)       // nothing more after the tail
}

@Test func int16InterleavedTargetsAreSupported() throws {
    let input = floatFormat(48_000, channels: 2)
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = try AudioBufferConverter(from: input, to: target)
    var outputs: [AVAudioPCMBuffer] = []
    for buffer in rampBuffers(input, count: 5, frames: 4_800) { outputs += try converter.convert(buffer) }
    outputs += try converter.flush()

    #expect(outputs.allSatisfy { $0.format == target && $0.int16ChannelData != nil })
    let last = try #require(outputs.last(where: { $0.frameLength > 100 }))
    let sample = last.int16ChannelData![0][Int(last.frameLength) - 100]
    #expect(sample > 20_000, "near the top of the ramp (0.9 × 32767), got \(sample)")
}

@Test func aBufferInAnotherFormatIsAReadableErrorNotACrash() throws {
    let converter = try AudioBufferConverter(from: floatFormat(48_000, channels: 1),
                                             to: floatFormat(16_000, channels: 1))
    let stranger = rampBuffers(floatFormat(44_100, channels: 1), count: 1, frames: 441)[0]
    #expect(throws: AudioConversionError.self) { try converter.convert(stranger) }
    do {
        _ = try converter.convert(stranger)
    } catch {
        #expect(error.localizedDescription.contains("44100"), "\(error.localizedDescription)")
    }
}

@Test func anImpossibleConversionIsAReadableError() {
    let input = floatFormat(48_000, channels: 1)
    let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1])!
    #expect(throws: AudioConversionError.self) { try AudioBufferConverter(from: input, to: aac) }
}

@Test func emptyBuffersProduceNothing() throws {
    let input = floatFormat(48_000, channels: 1)
    let converter = try AudioBufferConverter(from: input, to: floatFormat(16_000, channels: 1))
    let empty = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 16)!
    #expect(try converter.convert(empty).isEmpty)
}

@Test func frameCapacityCoversTheConvertedLength() {
    #expect(AudioBufferConverter.frameCapacity(for: 4_800, from: 48_000, to: 16_000) >= 1_600)
    #expect(AudioBufferConverter.frameCapacity(for: 4_410, from: 44_100, to: 16_000) >= 1_600)
    #expect(AudioBufferConverter.frameCapacity(for: 1_600, from: 16_000, to: 48_000) >= 4_800)
    #expect(AudioBufferConverter.frameCapacity(for: 0, from: 48_000, to: 16_000) > 0)
}
