import Foundation

/// Errors of `AppleSpeechEngine`. The coordinator shows `localizedDescription`, so every case
/// carries a readable message. Plain Foundation, so it is not gated by the SDK.
public enum AppleSpeechError: Error, Sendable, Equatable, LocalizedError {
    /// No installed speech model matches the requested locale (BCP-47 identifier).
    case localeNotInstalled(String)
    /// The analyzer offered no audio format for the transcriber.
    case noCompatibleAudioFormat
    /// The analyzer or transcriber failed; carries the underlying description.
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .localeNotInstalled(let identifier):
            "本机尚未安装“\(identifier)”的语音识别模型。"
        case .noCompatibleAudioFormat:
            "语音识别器没有提供可用的音频格式。"
        case .recognitionFailed(let reason):
            "语音识别失败：\(reason)"
        }
    }

    /// Keeps an `AppleSpeechError`; wraps any other error with its description.
    static func wrapping(_ error: any Error) -> AppleSpeechError {
        (error as? AppleSpeechError) ?? .recognitionFailed(error.localizedDescription)
    }
}

/// Picks the installed locale for `locale`: the same BCP-47 identifier; else, when `locale`
/// names a region, the first of the same language and region whatever its script (`zh-CN`
/// finds `zh-Hans-CN`); else the first installed locale of the same language.
func installedLocale(matching locale: Locale, in installed: [Locale]) -> Locale? {
    let wanted = locale.identifier(.bcp47)
    if let exact = installed.first(where: { $0.identifier(.bcp47) == wanted }) { return exact }
    guard let language = locale.language.languageCode else { return nil }
    return installed.first {
        $0.language.languageCode == language && (locale.region == nil || $0.region == locale.region)
    }
}

/// Turns transcriber results into `ASREvent`s that keep the ASREngine contract:
/// - final ranges are in seconds from the start of the input and never go backwards
///   (a final that starts before the previous one ended is clamped to that end;
///   a missing or non-finite time becomes the previous end);
/// - the coordinator clears its volatile text at every final, so a hypothesis that lies
///   entirely after the new final is sent again; one that overlaps it is dropped
///   (it would repeat finalized words) and the transcriber's next volatile replaces it.
///
/// Known gap, to be checked on a device: because an overlapping hypothesis is dropped whole,
/// the coordinator typically shows no volatile text after a final until the transcriber's next
/// volatile result. A possible improvement is to re-send only the hypothesis runs whose time
/// range starts at or after the final's end (the transcriber is already asked for
/// `.audioTimeRange`).
struct TranscriptEventMapper: Sendable {
    private(set) var lastFinalEnd: TimeInterval = 0
    private var hypothesis: (text: String, start: TimeInterval)?

    mutating func volatile(text: String, start: Double) -> [ASREvent] {
        hypothesis = text.isEmpty ? nil : (text, start.isFinite ? start : lastFinalEnd)
        return [.volatile(text: text)]
    }

    mutating func finalized(text: String, start: Double, end: Double) -> [ASREvent] {
        let lower = max(start.isFinite ? start : lastFinalEnd, lastFinalEnd)
        let upper = max(end.isFinite ? end : lower, lower)
        lastFinalEnd = upper
        var events: [ASREvent] = [.finalized(text: text, range: lower...upper)]
        if let hypothesis, hypothesis.start >= upper {
            events.append(.volatile(text: hypothesis.text))
        } else {
            hypothesis = nil
        }
        return events
    }
}
