import Foundation
import Testing
@testable import MeetingCore

@Test func theSupportedSourceLanguagesAreEnglishAndKorean() {
    #expect(SourceLanguage.all.map(\.identifier) == ["en-US", "ko-KR"])
    #expect(SourceLanguage.all.map(\.id) == ["en-US", "ko-KR"])
    #expect(SourceLanguage.all.map(\.name) == ["英语", "韩语"])
    #expect(SourceLanguage.all.map(\.locale) == [Locale(identifier: "en-US"), Locale(identifier: "ko-KR")])
    #expect(SourceLanguage.all.map { CaptionStrings.direction(from: $0.locale) } == ["英语 → 中文", "韩语 → 中文"])
}

@Test func eachLanguageCarriesItsOwnSelfTestSample() {
    #expect(SourceLanguage.english.spokenSentence == "The meeting will start at nine tomorrow morning.")
    #expect(SourceLanguage.english.keyword == "meeting")
    #expect(SourceLanguage.english.translatedSentence == "The meeting will start at nine.")
    #expect(SourceLanguage.korean.spokenSentence == "회의는 내일 아침 아홉 시에 시작합니다.")
    #expect(SourceLanguage.korean.keyword == "회의")
    #expect(SourceLanguage.korean.translatedSentence == "회의는 아홉 시에 시작합니다.")
}

@Test func aLocaleMatchesTheLanguageWithItsLanguageCode() {
    #expect(SourceLanguage.matching(Locale(identifier: "en-GB")) == .english)
    #expect(SourceLanguage.matching(Locale(identifier: "ko")) == .korean)
    #expect(SourceLanguage.matching(Locale(identifier: "ja-JP")) == nil)
    #expect(SourceLanguage.matching(Locale(identifier: "")) == nil)
}

@Test func aStoredIdentifierOutsideTheListFallsBackToEnglish() {
    #expect(SourceLanguage.stored("ko-KR") == .korean)
    #expect(SourceLanguage.stored("en-US") == .english)
    for other in [nil, "", "ja-JP", "en-GB", "garbage"] {
        #expect(SourceLanguage.stored(other) == .english)
    }
}
