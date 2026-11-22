import AVFoundation
import Foundation
import Observation

/// 把整条管线串起来：音频 → 识别 → 断句 → 存储 + 翻译队列 → 回写译文。
///
/// 收尾只有一条路径（`finish()`、音频流结束、识别流结束或抛错，先到者触发，只执行一次）：
/// `finishing` → 停音频 → 等音频尾部送完（≤1 秒）→ 等识别流结束（≤`engineDrainTimeout`）→ `flush()` → 入队
/// → `queue.finish()` 并回写全部结果（≤`translationDrainTimeout`）→ `endMeeting` → `idle`。
/// 识别流抛错（包括收尾期间）、写入失败或任一等待超时时为 `failed`，已存记录保留，会议照常结束。
@MainActor @Observable public final class SessionCoordinator {
    public enum State: Equatable, Sendable { case idle, preparing, listening, finishing, failed(String) }

    // `public internal(set)`: the `+Pipeline`/`+WrapUp` extensions in this module write these;
    // code outside the module can only read them.
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
    /// Store writes that failed this meeting; reported in the final `.failed` message (R14).
    @ObservationIgnored var unsavedSentences = 0
    @ObservationIgnored var unsavedResults = 0
    @ObservationIgnored var lastWriteError: (any Error)?
    @ObservationIgnored var endMeetingError: (any Error)?
    /// Error the recognition stream ended with, whenever it ended (also during wrap-up).
    @ObservationIgnored var engineError: (any Error)?
    /// Wrap-up bounds that fired this meeting; reported in the final `.failed` message.
    @ObservationIgnored var engineDrainTimedOut = false
    @ObservationIgnored var untranslatedSentences = 0
    /// Wrap-up fallback bound for the audio drain; internal so tests can shorten it.
    @ObservationIgnored var audioDrainTimeout = SessionCoordinator.defaultAudioDrainTimeout

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
        case .listening: await beginWrapUp().value
        case .finishing: await wrapUpTask?.value
        case .idle, .preparing, .failed: return
        }
    }

    /// Final state after wrap-up: an engine error and write failures are combined into one
    /// `.failed` message, so no loss is silent.
    func finalState() -> State {
        var problems: [String] = []
        if let engineError { problems.append(Self.hint(for: engineError)) }
        if engineDrainTimedOut { problems.append("识别在会议结束时未能及时完成，结尾的几句话可能没有被识别") }
        let reason = lastWriteError.map(Self.writeReason) ?? ""
        if unsavedSentences > 0 { problems.append("有 \(unsavedSentences) 句未能保存：\(reason)") }
        if unsavedResults > 0 { problems.append("有 \(unsavedResults) 条翻译结果未能保存：\(reason)") }
        if untranslatedSentences > 0 { problems.append("有 \(untranslatedSentences) 句尚未完成翻译（原文已保存）") }
        if let endMeetingError { problems.append("会议结束时间未能保存：\(Self.writeReason(endMeetingError))") }
        return problems.isEmpty ? .idle : .failed(problems.joined(separator: "；"))
    }

    static func writeReason(_ error: any Error) -> String {
        switch error {
        case TranscriptStore.StoreError.meetingNotFound: return "找不到会议记录"
        case TranscriptStore.StoreError.segmentNotFound: return "找不到句子记录"
        default: return error.localizedDescription
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
