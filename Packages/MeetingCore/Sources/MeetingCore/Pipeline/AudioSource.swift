import AVFoundation

/// 麦克风等音频来源。实现必须遵守以下约定（SessionCoordinator 依赖它们）：
/// - 每个 yield 出去的 buffer 都是新对象，来源此后再也不碰它（从 AVAudioEngine 的 tap 或
///   转换器 buffer 中先拷贝出来再 yield）。
/// - 流在 `stop()` 时、以及系统中断或音频路由丢失时结束；结束后不再 yield 任何东西。
/// - `stop()` 幂等，在流已自行结束后、以及 `start` 之前调用都安全；它不能丢弃已采集到的
///   buffer（先把它们 yield 出去，再结束流）。
/// - 运行中再次调用 `start` 必须抛错，或先结束上一个流。
/// - 输出格式与传给 `start` 的 `format` 完全一致。
public protocol AudioSource: Sendable {
    /// 开始采集并以指定格式输出；流在 stop() 或系统中断时结束
    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer>
    func stop() async
}

public enum AudioCaptureError: Error { case permissionDenied, engineStartFailed(String) }
