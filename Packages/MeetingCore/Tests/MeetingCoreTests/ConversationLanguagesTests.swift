import Foundation
import Testing
@testable import MeetingCore

@Test func sidesUseTheAgreedIdentifiers() {
    #expect(ConversationSide.allCases == [.chinese, .korean])
    #expect(ConversationSide.chinese.speechLocale.identifier(.bcp47) == "zh-CN")
    #expect(ConversationSide.korean.speechLocale.identifier(.bcp47) == "ko-KR")
    #expect(ConversationSide.chinese.translationLanguage == Locale.Language(identifier: "zh-Hans"))
    #expect(ConversationSide.korean.translationLanguage == Locale.Language(identifier: "ko"))
    #expect(ConversationSide.chinese.other == .korean)
    #expect(ConversationSide.korean.other == .chinese)
}
