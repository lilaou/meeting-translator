import Testing
import Foundation
import SwiftData
@testable import MeetingCore

@MainActor @Test func appendAssignsIncreasingIndexAndPendingStatus() throws {
    let store = try TranscriptStore.inMemory()
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    _ = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    _ = try store.append(Sentence(text: "Two.", start: 1, end: 2), to: m)
    let segs = try store.segments(of: m)
    #expect(segs.map(\.index) == [0, 1])
    #expect(segs.allSatisfy { $0.statusRaw == SegmentStatus.pendingTranslation.rawValue })
}

@MainActor @Test func setTranslationFillsTextAndStatus() throws {
    let store = try TranscriptStore.inMemory()
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    try store.setTranslation("一。", for: id)
    let seg = try store.segments(of: m)[0]
    #expect(seg.translatedText == "一。")
    #expect(seg.statusRaw == SegmentStatus.translated.rawValue)
}

@MainActor @Test func markFailedKeepsSourceText() throws {
    let store = try TranscriptStore.inMemory()
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    try store.markTranslationFailed(id)
    let seg = try store.segments(of: m)[0]
    #expect(seg.sourceText == "One.")
    #expect(seg.translatedText == nil)
    #expect(seg.statusRaw == SegmentStatus.translationFailed.rawValue)
}

@MainActor @Test func setTranslationOnTranslatedSegmentIsIgnored() throws {
    let store = try TranscriptStore.inMemory()
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    try store.setTranslation("一。", for: id)
    try store.setTranslation("壹。", for: id)
    let seg = try store.segments(of: m)[0]
    #expect(seg.translatedText == "一。")
}

@MainActor @Test func dataSurvivesNewContextOnSameContainer() throws {
    let container = try ModelContainer(
        for: Meeting.self, Segment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let first = TranscriptStore(container: container)
    let m = try first.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    _ = try first.append(Sentence(text: "One.", start: 0, end: 1), to: m)

    let second = TranscriptStore(container: container)
    _ = try second.append(Sentence(text: "Two.", start: 1, end: 2), to: m)
    let segs = try second.segments(of: m)
    #expect(segs.map(\.sourceText) == ["One.", "Two."])
    #expect(segs.map(\.index) == [0, 1])
}

@MainActor @Test func endMeetingSetsEndDateAndTitleDefaultsToStartTime() throws {
    let container = try ModelContainer(
        for: Meeting.self, Segment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = TranscriptStore(container: container)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: start)
    let end = start.addingTimeInterval(60)
    try store.endMeeting(m, at: end)
    let meetings = try container.mainContext.fetch(FetchDescriptor<Meeting>())
    #expect(meetings.count == 1)
    let meeting = meetings[0]
    #expect(meeting.endedAt == end)
    #expect(meeting.sourceLocaleID == "en-US")
    #expect(!meeting.title.isEmpty)
}
