import Foundation
import Testing
@testable import MeetingCore

@Test func sidesUseTheAgreedIdentifiers() {
    #expect(ConversationSide.allCases == [.chinese, .korean, .japanese, .english])
    #expect(ConversationSide.chinese.speechLocale.identifier(.bcp47) == "zh-CN")
    #expect(ConversationSide.korean.speechLocale.identifier(.bcp47) == "ko-KR")
    #expect(ConversationSide.chinese.translationLanguage == Locale.Language(identifier: "zh-Hans"))
    #expect(ConversationSide.korean.translationLanguage == Locale.Language(identifier: "ko"))
    #expect(ConversationSide.chinese.counterpart(partner: .korean) == .korean)
    #expect(ConversationSide.korean.counterpart(partner: .korean) == .chinese)
}

@Test func partnersAndTheirLanguages() {
    #expect(ConversationSide.partners == [.korean, .japanese, .english])
    #expect(ConversationSide.japanese.speechLocale.identifier(.bcp47) == "ja-JP")
    #expect(ConversationSide.english.speechLocale.identifier(.bcp47) == "en-US")
    #expect(ConversationSide.japanese.translationLanguage == Locale.Language(identifier: "ja"))
    #expect(ConversationSide.english.translationLanguage == Locale.Language(identifier: "en"))
    #expect(ConversationSide.japanese.rawValue == "japanese")
    #expect(ConversationSide.english.chineseName == "英语")
    #expect(ConversationSide.chinese.counterpart(partner: .japanese) == .japanese)
    #expect(ConversationSide.japanese.counterpart(partner: .japanese) == .chinese)
}

@Test func sidesAreNamedInChineseAndInTheirOwnLanguage() {
    #expect(ConversationSide.allCases.map(\.chineseName) == ["中文", "韩语", "日语", "英语"])
    #expect(ConversationSide.allCases.map(\.nativeName) == ["中文", "한국어", "日本語", "English"])
}

@Test(arguments: [(nil, ConversationSide.korean), ("", .korean), ("chinese", .korean),
                  ("malay", .korean), ("japanese", .japanese), ("english", .english),
                  ("korean", .korean)])
func rememberedPartner(raw: String?, expected: ConversationSide) {
    #expect(ConversationSide.storedPartner(raw) == expected)
}
