import Foundation

/// One side of a face-to-face conversation: the language that side speaks and reads. What one
/// side says is translated into the `other` side's `translationLanguage`.
public enum ConversationSide: String, Sendable, CaseIterable {
    case chinese
    case korean

    public var other: ConversationSide {
        switch self {
        case .chinese: .korean
        case .korean: .chinese
        }
    }

    /// The locale this side's speech is recognized in.
    public var speechLocale: Locale {
        switch self {
        case .chinese: Locale(identifier: "zh-CN")
        case .korean: SourceLanguage.korean.locale
        }
    }

    /// The language translated into for this side to read; Chinese is the meeting's
    /// `TranslationTarget.language`.
    public var translationLanguage: Locale.Language {
        switch self {
        case .chinese: TranslationTarget.language
        case .korean: Locale.Language(identifier: "ko")
        }
    }
}
