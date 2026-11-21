import AVFoundation
import Foundation
import Observation

/// 把整条管线串起来：音频 → 识别 → 断句 → 存储 + 翻译队列 → 回写译文。
///
/// 收尾只有一条路径（`finish()`、音频流结束、识别流结束或抛错，先到者触发，只执行一次）：
/// `finishing` → 停音频 → 等识别流结束 → `flush()` → 入队 → `queue.finish()` → 回写全部结果
/// → `endMeeting` → `idle`（识别流抛错触发时为 `failed`，已存记录保留）。
@MainActor @Observable public final class SessionCoordinator {
    public enum State: Equatable { case idle, preparing, listening, finishing, failed(String) }

    public internal(set) var state: State = .idle
    /// 当前临时原文；有定稿到达时清空
    public internal(set) var volatileText = ""
    public internal(set) var isTranslationLagging = false
    public internal(set) var meetingID: UUID?
    public internal(set) var startedAt: Date?

    @ObservationIgnored let engine: any ASREngine
    @ObservationIgnored let translator: any Translator
    @ObservationIgnored let audio: any AudioSource
    @ObservationIgnored let readiness: any ReadinessChecking
    @ObservationIgnored let store: TranscriptStore
    @ObservationIgnored let config: PipelineConfig

    // Per-meeting pipeline state; reset by `start`, every task is awaited by `wrapUp`.
    @ObservationIgnored var assembler: SentenceAssembler
    @ObservationIgnored var queue: TranslationQueue?
    @ObservationIgnored var engineAudio: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @ObservationIgnored var forwardTask: Task<Void, Never>?
    @ObservationIgnored var audioEndTask: Task<Void, Never>?
    @ObservationIgnored var engineTask: Task<Void, Never>?
    @ObservationIgnored var outcomeTask: Task<Void, Never>?
    @ObservationIgnored var laggingTask: Task<Void, Never>?
    @ObservationIgnored var pauseTask: Task<Void, Never>?
    /// Tail of the serial chain of `queue.enqueue` calls (keeps enqueue order = append order).
    @ObservationIgnored var enqueueTail: Task<Void, Never>?
    @ObservationIgnored var wrapUpTask: Task<Void, Never>?

    public init(engine: any ASREngine, translator: any Translator, audio: any AudioSource,
                readiness: any ReadinessChecking, store: TranscriptStore, config: PipelineConfig) {
        self.engine = engine
        self.translator = translator
        self.audio = audio
        self.readiness = readiness
        self.store = store
        self.config = config
        self.assembler = SentenceAssembler(maxCharacters: config.maxSentenceCharacters)
    }

    /// 仅在 `idle` 或 `failed` 时生效。预检通过后才建会议；之后任一步失败都会结束该会议。
    public func start(locale: Locale) async {
        switch state {
        case .idle, .failed: break
        case .preparing, .listening, .finishing: return
        }
        state = .preparing
        volatileText = ""
        isTranslationLagging = false
        meetingID = nil
        startedAt = nil
        do {
            try await readiness.preflight(locale: locale)
        } catch {
            state = .failed(Self.hint(for: error))
            return
        }
        let now = Date()
        var created: UUID?
        do {
            let id = try store.startMeeting(locale: locale, at: now)
            created = id
            let wiring = try await Self.connect(engine: engine, audio: audio, locale: locale)
            meetingID = id
            startedAt = now
            launchPipeline(wiring, locale: locale)
            state = .listening
        } catch {
            if let created { try? store.endMeeting(created, at: Date()) }
            state = .failed(Self.hint(for: error))
        }
    }

    /// 仅在 `listening` 时触发收尾；收尾已在进行时等它完成。返回时会议已结束、译文已全部回写。
    public func finish() async {
        switch state {
        case .listening: await beginWrapUp(error: nil).value
        case .finishing: await wrapUpTask?.value
        case .idle, .preparing, .failed: return
        }
    }

    static func hint(for error: any Error) -> String {
        switch error {
        case let failure as ReadinessFailure:
            switch failure {
            case .speechPackMissing: return "语音识别离线包未安装，请先下载"
            case .translationPackMissing: return "翻译离线包未安装，请先下载"
            case .selfTestFailed(let detail): return "离线自检未通过：\(detail)"
            }
        case let failure as AudioCaptureError:
            switch failure {
            case .permissionDenied: return "没有麦克风权限，请在系统设置中允许"
            case .engineStartFailed(let detail): return "无法启动录音：\(detail)"
            }
        default:
            return "出现错误：\(error.localizedDescription)"
        }
    }
}
