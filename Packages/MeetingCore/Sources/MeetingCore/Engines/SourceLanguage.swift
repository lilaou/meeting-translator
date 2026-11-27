import Foundation

/// A source language the app supports, with the sample its offline self-test uses. `all` is
/// the single list of them; a new language is a new entry here (the system packs and the
/// voice must exist on the device).
public struct SourceLanguage: Sendable, Equatable, Identifiable {
    /// BCP-47 identifier: the locale of a meeting, the voice of the self-test and the value
    /// the app remembers.
    public let identifier: String
    /// What the self-test audio says.
    let spokenSentence: String
    /// The word the self-test transcript must contain (ignoring case).
    let keyword: String
    /// What the self-test translates.
    let translatedSentence: String

    public var id: String { identifier }
    public var locale: Locale { Locale(identifier: identifier) }
    /// The Chinese name of the language ("英语"), as in the translation direction.
    public var name: String { CaptionStrings.languageName(of: locale) }

    static let english = SourceLanguage(
        identifier: "en-US",
        spokenSentence: "The meeting will start at nine tomorrow morning.",
        keyword: "meeting",
        translatedSentence: "The meeting will start at nine.")
    static let korean = SourceLanguage(
        identifier: "ko-KR",
        spokenSentence: "회의는 내일 아침 아홉 시에 시작합니다.",
        keyword: "회의",
        translatedSentence: "회의는 아홉 시에 시작합니다.")

    /// The supported languages, in the order they are offered; the first is the default.
    public static let all: [SourceLanguage] = [english, korean]

    /// The entry with `locale`'s language code (so "en-GB" uses the English sample).
    static func matching(_ locale: Locale) -> SourceLanguage? {
        guard let code = locale.language.languageCode else { return nil }
        return all.first { $0.locale.language.languageCode == code }
    }

    /// The language for a remembered identifier; the default for none or an unlisted one.
    static func stored(_ identifier: String?) -> SourceLanguage {
        all.first { $0.identifier == identifier } ?? english
    }
}
