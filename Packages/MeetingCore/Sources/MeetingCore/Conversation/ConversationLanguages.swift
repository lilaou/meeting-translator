import Foundation

/// One side of a face-to-face conversation: the language that side speaks and reads. The app's
/// user is always `chinese`; the other side is one of `partners`. What one side says is
/// translated into its `counterpart`'s `translationLanguage`.
public enum ConversationSide: String, Sendable, CaseIterable {
    case chinese
    case korean
    case japanese
    case english

    /// The languages the other side can have, in the order they are offered.
    public static let partners: [ConversationSide] = [.korean, .japanese, .english]

    /// The partner for a remembered raw value; Korean for none or one that is not a partner.
    public static func storedPartner(_ raw: String?) -> ConversationSide {
        partners.first { $0.rawValue == raw } ?? .korean
    }

    /// The side this one talks with, in a conversation between Chinese and `partner`.
    public func counterpart(partner: ConversationSide) -> ConversationSide {
        self == .chinese ? partner : .chinese
    }

    /// The locale this side's speech is recognized in.
    public var speechLocale: Locale {
        switch self {
        case .chinese: Locale(identifier: "zh-CN")
        case .korean: SourceLanguage.korean.locale
        case .japanese: Locale(identifier: "ja-JP")
        case .english: Locale(identifier: "en-US")
        }
    }

    /// The language translated into for this side to read; Chinese is the meeting's
    /// `TranslationTarget.language`.
    public var translationLanguage: Locale.Language {
        switch self {
        case .chinese: TranslationTarget.language
        case .korean: Locale.Language(identifier: "ko")
        case .japanese: Locale.Language(identifier: "ja")
        case .english: Locale.Language(identifier: "en")
        }
    }

    /// The language's name in Chinese.
    public var chineseName: String {
        switch self {
        case .chinese: "中文"
        case .korean: "韩语"
        case .japanese: "日语"
        case .english: "英语"
        }
    }

    /// The language's name in itself, so the other side can point at it.
    public var nativeName: String {
        switch self {
        case .chinese: "中文"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}
