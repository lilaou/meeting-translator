import Foundation
import Testing
@testable import MeetingCore

private func answer(_ identifier: String?, _ text: String) -> TranslatedText {
    TranslatedText(identifier: identifier, text: text)
}

@Test func orderedTranslationsFollowTheIdentifiersNotTheArrivalOrder() throws {
    let answers = [answer("2", "丙"), answer("0", "甲"), answer("1", "乙")]
    #expect(try orderedTranslations(answers, count: 3) == ["甲", "乙", "丙"])
}

@Test func orderedTranslationsOfAnEmptyBatchIsEmpty() throws {
    #expect(try orderedTranslations([], count: 0) == [])
}

@Test func orderedTranslationsThrowOnACountMismatch() {
    #expect(throws: AppleTranslatorError.mismatchedResults) {
        try orderedTranslations([answer("0", "甲")], count: 2)
    }
    #expect(throws: AppleTranslatorError.mismatchedResults) {
        try orderedTranslations([answer("0", "甲"), answer("1", "乙")], count: 1)
    }
}

@Test(arguments: [[answer(nil, "甲"), answer("1", "乙")],      // missing identifier
                  [answer("0", "甲"), answer("0", "乙")],      // repeated
                  [answer("0", "甲"), answer("2", "乙")],      // out of range
                  [answer("0", "甲"), answer("x", "乙")]])     // not an index
func orderedTranslationsThrowWhenTheIdentifiersDoNotMatch(_ answers: [TranslatedText]) {
    #expect(throws: AppleTranslatorError.mismatchedResults) {
        try orderedTranslations(answers, count: 2)
    }
}

@Test(arguments: ["", " ", "\n\t"])
func orderedTranslationsThrowTheWholeBatchOnABlankText(_ blank: String) {
    #expect(throws: AppleTranslatorError.emptyResult) {
        try orderedTranslations([answer("0", "甲"), answer("1", blank)], count: 2)
    }
}

@Test func appleTranslatorErrorsAreReadableAndWrapOtherErrors() {
    #expect(AppleTranslatorError.packNotInstalled("en").localizedDescription.contains("en"))
    #expect(AppleTranslatorError.wrapping(AppleTranslatorError.emptyResult) == .emptyResult)
    let wrapped = AppleTranslatorError.wrapping(FakeError.translation)
    guard case .translationFailed = wrapped else {
        Issue.record("expected translationFailed, got \(wrapped)")
        return
    }
}
