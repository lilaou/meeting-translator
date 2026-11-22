import Foundation
import Testing
@testable import MeetingCore

// MARK: - strings

@Test func captionStringsAreFixed() {
    #expect(CaptionStrings.offline == "离线")
    #expect(CaptionStrings.lagging == "翻译滞后")
    #expect(CaptionStrings.start == "开始会议")
    #expect(CaptionStrings.finish == "结束会议")
    #expect(CaptionStrings.backToLatest == "回到最新")
}

@Test func directionNamesTheSourceLanguageInChinese() {
    #expect(CaptionStrings.direction(from: Locale(identifier: "en-US")) == "英语 → 中文")
    #expect(CaptionStrings.direction(from: Locale(identifier: "en-GB")) == "英语 → 中文")
    #expect(CaptionStrings.direction(from: Locale(identifier: "ja-JP")) == "日语 → 中文")
}

@Test func directionNeverHasAnEmptySourceName() {
    #expect(CaptionStrings.direction(from: Locale(identifier: "")) == "未知语言 → 中文")
}

// MARK: - elapsed time

private let elapsedCases: [(Double, String)] = [
    (0, "00:00:00"), (59, "00:00:59"), (59.9, "00:00:59"), (60, "00:01:00"),
    (3_600, "01:00:00"), (2 * 3_600 + 42 * 60 + 17, "02:42:17"), (42 * 60 + 17, "00:42:17"),
    (100 * 3_600, "100:00:00"), (-5, "00:00:00"),
]

@Test(arguments: elapsedCases)
func elapsedTextIsZeroPaddedHoursMinutesSeconds(seconds: Double, expected: String) {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    #expect(CaptionFormatting.elapsedText(since: start, now: start.addingTimeInterval(seconds)) == expected)
}

// MARK: - segment display

@Test func aTranslatedSegmentShowsItsTranslation() {
    let display = SegmentDisplay(status: .translated, sourceText: "Hello.", translatedText: "你好。")
    #expect(display.kind == .translated)
    #expect(display.sourceText == "Hello.")
    #expect(display.translationText == "你好。")
}

@Test func aPendingSegmentShowsAnEllipsis() {
    let display = SegmentDisplay(status: .pendingTranslation, sourceText: "Hello.", translatedText: nil)
    #expect(display.kind == .pending)
    #expect(display.sourceText == "Hello.")
    #expect(display.translationText == "…")
}

@Test func aTranslatedSegmentWithoutATranslationIsShownAsPending() {
    let display = SegmentDisplay(status: .translated, sourceText: "Hello.", translatedText: nil)
    #expect(display.kind == .pending)
    #expect(display.translationText == "…")
}

@Test func aFailedSegmentKeepsItsSourceText() {
    let display = SegmentDisplay(status: .translationFailed, sourceText: "Hello.", translatedText: nil)
    #expect(display.kind == .failed)
    #expect(display.sourceText == "Hello.")
    #expect(display.translationText == "（翻译失败）")
}

@Test func anInterruptionMarkerIsShownAsAMarker() {
    let display = SegmentDisplay(status: .interruptionMarker, sourceText: "", translatedText: nil)
    #expect(display.kind == .interruption)
    #expect(display.translationText == "（录音中断）")
}

@MainActor @Test func aSegmentIsDisplayedFromItsStoredValues() {
    let segment = Segment(index: 0, sourceText: "Hello.", startTime: 0, endTime: 1, status: .translated)
    segment.translatedText = "你好。"
    #expect(SegmentDisplay(segment)
            == SegmentDisplay(status: .translated, sourceText: "Hello.", translatedText: "你好。"))
}

// MARK: - scroll follow

@Test func scrollFollowStartsFollowing() {
    let state = ScrollFollowState()
    #expect(state.isFollowing)
    #expect(state.shouldScrollOnNewContent)
    #expect(!state.showsBackToLatest)
}

@Test func scrollingAwayStopsFollowingAndScrollingBackResumes() {
    var state = ScrollFollowState()
    state.userScrolled(isAtBottom: false)
    #expect(!state.isFollowing)
    #expect(!state.shouldScrollOnNewContent)
    #expect(state.showsBackToLatest)

    state.userScrolled(isAtBottom: false)
    #expect(!state.isFollowing)

    state.userScrolled(isAtBottom: true)
    #expect(state.isFollowing)
    #expect(state.shouldScrollOnNewContent)
    #expect(!state.showsBackToLatest)
}

@Test func jumpToLatestResumesFollowing() {
    var state = ScrollFollowState()
    state.userScrolled(isAtBottom: false)
    state.jumpToLatest()
    #expect(state.isFollowing)
    #expect(state.shouldScrollOnNewContent)
    #expect(!state.showsBackToLatest)
    state.jumpToLatest()
    #expect(state.isFollowing)
}

@Test func languageNameFallsBackWhenTheSystemHasNoName() {
    let noNames: (String) -> String? = { _ in nil }
    #expect(CaptionStrings.languageName(of: Locale(identifier: "en-US"), names: noNames) == "en")
    #expect(CaptionStrings.languageName(of: Locale(identifier: "en-US"), names: { _ in "" }) == "en")
    #expect(CaptionStrings.languageName(of: Locale(identifier: ""), names: noNames) == "未知语言")
    #expect(CaptionStrings.languageName(of: Locale(identifier: "en-US"), names: { $0 == "en" ? "英语" : nil })
            == "英语")
}
