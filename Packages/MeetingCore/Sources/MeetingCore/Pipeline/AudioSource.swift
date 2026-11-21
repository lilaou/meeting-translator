import AVFoundation

public protocol AudioSource: Sendable {
    /// 开始采集并以指定格式输出；流在 stop() 或系统中断时结束
    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer>
    func stop() async
}

public enum AudioCaptureError: Error { case permissionDenied, engineStartFailed(String) }
