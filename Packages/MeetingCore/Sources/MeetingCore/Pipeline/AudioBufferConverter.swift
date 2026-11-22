import AVFoundation
import Foundation

/// Why a capture buffer could not be converted; readable, never a crash.
enum AudioConversionError: Error, Equatable, LocalizedError {
    /// No converter exists between the two formats (or the target is not linear PCM).
    case unsupported(String)
    /// A buffer arrived in another format than the converter was built for.
    case formatMismatch(String)
    case allocationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let formats): "无法转换音频格式：\(formats)"
        case .formatMismatch(let formats): "音频格式与预期不符：\(formats)"
        case .allocationFailed: "无法分配音频缓冲区"
        case .conversionFailed(let reason): "音频转换失败：\(reason)"
        }
    }
}

/// Converts buffers of one input (hardware) format into fresh buffers of exactly the target
/// format through one reused `AVAudioConverter`, keeping the resampler's state between
/// buffers, and returns the resampler's tail on `flush()` at the end of the stream.
///
/// Every returned buffer is allocated by this call and never touched by the converter again,
/// so the caller may hand it over; for identical formats the samples are still copied into a
/// new buffer, never the input. Not Sendable: one owner at a time (`AudioCapture` keeps it
/// behind the capture gate's lock).
final class AudioBufferConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws(AudioConversionError) {
        let formats = "\(Self.describe(input)) → \(Self.describe(output))"
        guard input.commonFormat != .otherFormat, output.commonFormat != .otherFormat,
              let converter = AVAudioConverter(from: input, to: output)
        else { throw .unsupported(formats) }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    /// Output frames needed for `frames` input frames, plus room for the resampler's
    /// held-back frames; never zero.
    static func frameCapacity(for frames: AVAudioFrameCount, from inputRate: Double,
                              to outputRate: Double) -> AVAudioFrameCount {
        let scaled = (Double(frames) * outputRate / max(inputRate, 1)).rounded(.up)
        return AVAudioFrameCount(min(scaled, Double(UInt32.max / 2))) + 256
    }

    /// Converts `buffer` (in `inputFormat`); may return no buffer, one, or several.
    func convert(_ buffer: AVAudioPCMBuffer) throws(AudioConversionError) -> [AVAudioPCMBuffer] {
        guard buffer.format == inputFormat else {
            throw .formatMismatch("\(Self.describe(buffer.format)) ≠ \(Self.describe(inputFormat))")
        }
        guard buffer.frameLength > 0 else { return [] }
        return try drain(buffer)
    }

    /// Ends the stream: returns what the resampler still holds, then resets the converter so
    /// it can start a new stream.
    func flush() throws(AudioConversionError) -> [AVAudioPCMBuffer] {
        defer { converter.reset() }
        return try drain(nil)
    }

    /// Feeds `input` once (or the end of the stream when nil) and collects the output in new
    /// buffers until the converter has used it up.
    private func drain(_ input: AVAudioPCMBuffer?) throws(AudioConversionError) -> [AVAudioPCMBuffer] {
        // `convert` calls the (Sendable-typed) input block synchronously on this thread
        // before it returns, so the feed is never used concurrently.
        nonisolated(unsafe) let feed = InputFeed(input)
        let capacity = Self.frameCapacity(for: input?.frameLength ?? 0,
                                          from: inputFormat.sampleRate, to: outputFormat.sampleRate)
        var outputs: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw .allocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                feed.next(inputStatus)
            }
            if status == .error {
                throw .conversionFailed(error?.localizedDescription ?? "unknown error")
            }
            if output.frameLength > 0 { outputs.append(output) }
            // `.haveData`: the output filled up and more is waiting; anything else means the
            // input is used up (`.inputRanDry`) or the stream ended (`.endOfStream`).
            guard status == .haveData, output.frameLength > 0 else { return outputs }
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let sample = switch format.commonFormat {
        case .pcmFormatFloat32: "float32"
        case .pcmFormatFloat64: "float64"
        case .pcmFormatInt16: "int16"
        case .pcmFormatInt32: "int32"
        default: "other"
        }
        let layout = format.isInterleaved ? "interleaved" : "non-interleaved"
        return "\(Int(format.sampleRate)) Hz \(format.channelCount) ch \(sample) \(layout)"
    }
}

/// Hands the converter its input once, then reports "no data now" (or the end of the
/// stream when there is no input), so the resampler keeps its state for the next buffer.
private final class InputFeed {
    private var pending: AVAudioPCMBuffer?
    private let endOfStream: Bool

    init(_ input: AVAudioPCMBuffer?) {
        pending = input
        endOfStream = input == nil
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer = pending {
            pending = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
    }
}
