import Testing
@testable import MeetingCore

/// What each half shows for the notice of a turn: the Korean half never gets Chinese text.
private typealias Notice = ConversationSession.Notice

@Test func theKoreanHalfShowsOnlyItsOwnFixedLines() {
    #expect(Notice.failed("原因").shown(on: .korean, speaker: .korean) == .failed)
    #expect(Notice.notHeard.shown(on: .korean, speaker: .korean) == .notHeard)
    #expect(Notice.failed("原因").shown(on: .korean, speaker: .chinese) == nil)
    #expect(Notice.notHeard.shown(on: .korean, speaker: .chinese) == nil)
}

@Test func theChineseHalfShowsTheReasonWhoeverSpoke() {
    #expect(Notice.failed("原因").shown(on: .chinese, speaker: .chinese) == .reason("原因"))
    #expect(Notice.failed("原因").shown(on: .chinese, speaker: .korean) == .reason("对方这次出错了：原因"))
}

@Test func onlyTheSpeakerIsToldThatNothingWasHeard() {
    #expect(Notice.notHeard.shown(on: .chinese, speaker: .chinese) == .notHeard)
    #expect(Notice.notHeard.shown(on: .chinese, speaker: .korean) == nil)
}
