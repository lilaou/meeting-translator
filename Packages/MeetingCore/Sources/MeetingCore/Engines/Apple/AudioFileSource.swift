import AVFoundation
import Foundation

public enum AudioFileSourceError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedConversion
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedConversion: "无法把音频文件转换成识别所需的格式。"
        case .conversionFailed(let reason): "音频文件转换失败：\(reason)"
        }
    }
}

/// 把音频文件读成缓冲流，供回归和引擎对比使用。
///
/// The whole file is read and converted to `format` before this returns (so read and
/// conversion errors are thrown here, and no task holds the non-Sendable file or converter);
/// the stream then yields the converted buffers in order, each a new object, and finishes.
/// Meant for benchmark recordings of a few minutes, which fit in memory.
public func audioBuffers(fromFile url: URL, format: AVAudioFormat) throws -> AsyncStream<AVAudioPCMBuffer> {
    let file = try AVAudioFile(forReading: url)
    let source = file.processingFormat
    guard let converter = AVAudioConverter(from: source, to: format) else {
        throw AudioFileSourceError.unsupportedConversion
    }
    let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    let chunk: AVAudioFrameCount = 4096
    let capacity = AVAudioFrameCount((Double(chunk) * format.sampleRate / source.sampleRate).rounded(.up)) + 64
    var inputEnded = false
    var readError: (any Error)?

    while true {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioFileSourceError.unsupportedConversion
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { packets, inputStatus in
            guard !inputEnded, file.framePosition < file.length,
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: packets) else {
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: packets)
            } catch {
                readError = error
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let readError { throw readError }
        if status == .error {
            throw AudioFileSourceError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        if output.frameLength > 0 {
            // `output` shares a region with the converter only because both were arguments
            // of `convert`; nothing here touches it again, so yielding it hands it over.
            nonisolated(unsafe) let handoff = output
            continuation.yield(handoff)
        }
        if status == .endOfStream { break }
    }
    continuation.finish()
    return stream
}
