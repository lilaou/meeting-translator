import Foundation

/// The fixed texts of the caption screen, in one place.
public enum CaptionStrings {
    /// Badge: everything runs on the device.
    public static let offline = "离线"
    /// Badge while translation is behind recognition.
    public static let lagging = "翻译滞后"
    /// Button that starts a meeting.
    public static let start = "开始会议"
    /// Button that ends the meeting.
    public static let finish = "结束会议"
    /// Button that scrolls back to the newest caption and resumes following.
    public static let backToLatest = "回到最新"

    /// The translation direction, e.g. "英语 → 中文" for `en-US`. The target is always
    /// Simplified Chinese; an unnamed source language shows its code (or the locale
    /// identifier), and a locale without either shows "未知语言".
    public static func direction(from source: Locale) -> String {
        "\(languageName(of: source)) → 中文"
    }

    static let pendingTranslation = "…"
    static let translationFailed = "（翻译失败）"
    static let interruption = "（录音中断）"
    static let unknownLanguage = "未知语言"

    private static let chinese = Locale(identifier: "zh-Hans")

    /// The Chinese name of `locale`'s language ("英语"), else its code, else the locale
    /// identifier, else "未知语言"; never empty. `names` looks a code up (injectable for tests).
    static func languageName(of locale: Locale,
                             names: (String) -> String? = { chinese.localizedString(forLanguageCode: $0) })
        -> String {
        let code = locale.language.languageCode?.identifier ?? ""
        let candidates = [code.isEmpty ? nil : names(code), code, locale.identifier]
        return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? unknownLanguage
    }
}

/// Formatting for the caption screen.
public enum CaptionFormatting {
    /// Elapsed whole seconds as zero-padded "HH:MM:SS" ("00:42:17"); hours grow past two
    /// digits ("100:00:00"); zero, negative or non-finite intervals read "00:00:00".
    public static func elapsedText(since start: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(start)
        // Capped far beyond any meeting so the conversion to Int can never trap.
        let seconds = interval.isFinite && interval > 0 ? Int(min(interval, 1e12)) : 0
        let hours = seconds / 3_600, minutes = seconds / 60 % 60
        return [hours, minutes, seconds % 60].map(twoDigits).joined(separator: ":")
    }

    /// At least two digits, zero-padded ("07", "42", "100").
    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

/// What one caption row shows for a stored segment.
public struct SegmentDisplay: Equatable, Sendable {
    /// Which of the row's presentations applies.
    public enum Kind: Equatable, Sendable {
        /// The translation is shown.
        case translated
        /// No translation yet: "…".
        case pending
        /// Translation failed: "（翻译失败）", the source text stays.
        case failed
        /// Recording was interrupted here: "（录音中断）".
        case interruption
    }

    /// How the row is presented.
    public let kind: Kind
    /// The recognized text (shown small, above).
    public let sourceText: String
    /// The text in the translation's place (shown large, below).
    public let translationText: String

    /// A `translated` status without a translated text is shown as pending.
    public init(status: SegmentStatus, sourceText: String, translatedText: String?) {
        self.sourceText = sourceText
        switch status {
        case .translated:
            if let translatedText {
                (kind, translationText) = (.translated, translatedText)
            } else {
                (kind, translationText) = (.pending, CaptionStrings.pendingTranslation)
            }
        case .pendingTranslation: (kind, translationText) = (.pending, CaptionStrings.pendingTranslation)
        case .translationFailed: (kind, translationText) = (.failed, CaptionStrings.translationFailed)
        case .interruptionMarker: (kind, translationText) = (.interruption, CaptionStrings.interruption)
        }
    }

    /// From a stored segment (as read with `@Query`).
    public init(_ segment: Segment) {
        self.init(status: segment.status, sourceText: segment.sourceText,
                  translatedText: segment.translatedText)
    }
}
