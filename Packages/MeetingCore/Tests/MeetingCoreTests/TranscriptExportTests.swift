import Testing
import Foundation
import SwiftData
@testable import MeetingCore

// History task 3: what a saved record looks like as a document, as text and as Markdown.

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
/// 2026-11-28 14:30:00 in Asia/Shanghai (06:30:00 UTC).
private let began = Date(timeIntervalSince1970: 1_795_847_400)

private typealias Line = (source: String, translation: String?, start: TimeInterval, status: SegmentStatus)

/// A meeting in `container`, its segments indexed in the order given and inserted backwards.
@MainActor private func meeting(in container: ModelContainer, lasting duration: TimeInterval?,
                                _ lines: [Line]) throws -> Meeting {
    let context = container.mainContext
    let meeting = Meeting(title: "stored title", startedAt: began, sourceLocaleID: "en-US")
    meeting.endedAt = duration.map { began.addingTimeInterval($0) }
    context.insert(meeting)
    for (index, line) in lines.enumerated().reversed() {
        let segment = Segment(index: index, sourceText: line.source, startTime: line.start,
                              endTime: line.start + 1, status: line.status)
        segment.translatedText = line.translation
        context.insert(segment)
        segment.meeting = meeting
    }
    try context.save()
    return meeting
}

@MainActor private func conversation(
    in container: ModelContainer,
    _ turns: [(side: ConversationSide, original: String, translation: String?, after: TimeInterval)]
) throws -> ConversationRecord {
    let context = container.mainContext
    let record = ConversationRecord(startedAt: began, languageCodes: ["zh", "ko"])
    context.insert(record)
    for (index, turn) in turns.enumerated().reversed() {
        let stored = ConversationTurnRecord(index: index, speakerCode: turn.side.rawValue,
                                            original: turn.original, translation: turn.translation,
                                            date: began.addingTimeInterval(turn.after))
        context.insert(stored)
        stored.conversation = record
    }
    try context.save()
    return record
}

private let sample: [Line] = [
    ("Good morning.", "早上好。", 5, .translated),
    ("", nil, 61, .interruptionMarker),
    ("Budget review.\nSecond line.", "预算评审。", 3_725, .translated),
]

@MainActor @Test func meetingTextExportMatchesExactly() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let document = TranscriptDocument(
        meeting: try meeting(in: container, lasting: 2_537, sample), timeZone: shanghai)
    #expect(document.kind == .meeting)
    #expect(document.startedAt == began)
    #expect(TranscriptExport.render(document, as: .text) == """
        会议记录 2026-11-28 14:30
        语言：英语 → 中文
        时长：00:42:17

        [00:00:05]
        Good morning.
        早上好。

        [00:01:01]
        （录音中断）

        [01:02:05]
        Budget review.
        Second line.
        预算评审。

        """)
}

@MainActor @Test func meetingMarkdownExportMatchesExactly() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let document = TranscriptDocument(
        meeting: try meeting(in: container, lasting: 2_537, sample), timeZone: shanghai)
    #expect(TranscriptExport.render(document, as: .markdown) == """
        # 会议记录 2026-11-28 14:30

        - 语言：英语 → 中文
        - 时长：00:42:17

        **00:00:05**

        > Good morning.

        早上好。

        **00:01:01**

        > （录音中断）

        **01:02:05**

        > Budget review.
        > Second line.

        预算评审。

        """)
}

@MainActor @Test func conversationExportShowsSpeakersAndClockTimes() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let record = try conversation(in: container, [
        (.chinese, "你好。", "안녕하세요.", 62),
        (.korean, "반갑습니다.", "很高兴见到你。", 75),
    ])
    let document = TranscriptDocument(conversation: record, timeZone: shanghai)
    #expect(document.kind == .conversation)
    #expect(document.startedAt == began)
    #expect(TranscriptExport.render(document, as: .text) == """
        面对面对话 2026-11-28 14:30
        语言：中文 ↔ 韩语

        [14:31:02 中文方]
        你好。
        안녕하세요.

        [14:31:15 韩语方]
        반갑습니다.
        很高兴见到你。

        """)
    #expect(TranscriptExport.render(document, as: .markdown) == """
        # 面对面对话 2026-11-28 14:30

        - 语言：中文 ↔ 韩语

        **14:31:02 中文方**

        > 你好。

        안녕하세요.

        **14:31:15 韩语方**

        > 반갑습니다.

        很高兴见到你。

        """)
}

@MainActor @Test func unfinishedMeetingHasNoDurationButAllSentences() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let document = TranscriptDocument(
        meeting: try meeting(in: container, lasting: nil, [
            ("One.", "一。", 0, .translated), ("Two.", nil, 2, .pendingTranslation),
        ]), timeZone: shanghai)
    #expect(document.title == "会议记录 2026-11-28 14:30")
    #expect(document.metadata == ["语言：英语 → 中文"])
    #expect(document.entries.map(\.original) == ["One.", "Two."])
    #expect(document.entries.map(\.label) == ["00:00:00", "00:00:02"])
}

@MainActor @Test func missingTranslationsAreNamed() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let meetingDocument = TranscriptDocument(
        meeting: try meeting(in: container, lasting: nil, [
            ("Waiting.", nil, 0, .pendingTranslation),
            ("Broken.", nil, 1, .translationFailed),
            ("Lost.", nil, 2, .translated),
            ("Empty.", "", 3, .translated),
        ]), timeZone: shanghai)
    #expect(meetingDocument.entries.map(\.translation)
        == ["（未翻译）", "（翻译失败）", "（未翻译）", "（未翻译）"])
    let conversationDocument = TranscriptDocument(
        conversation: try conversation(in: container, [
            (.chinese, "你好。", nil, 0), (.chinese, "再见。", "", 1),
        ]), timeZone: shanghai)
    #expect(conversationDocument.entries.map(\.translation) == ["（翻译失败）", "（未翻译）"])
}

@MainActor @Test func fileNamesCarryKindAndTime() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let meetingDocument = TranscriptDocument(
        meeting: try meeting(in: container, lasting: nil, []), timeZone: shanghai)
    let conversationDocument = TranscriptDocument(
        conversation: try conversation(in: container, []), timeZone: shanghai)
    #expect(TranscriptExport.fileName(for: meetingDocument, as: .text, timeZone: shanghai)
        == "会议-20261128-1430.txt")
    #expect(TranscriptExport.fileName(for: conversationDocument, as: .markdown, timeZone: shanghai)
        == "对话-20261128-1430.md")
    #expect(TranscriptExport.fileName(for: meetingDocument, as: .text, timeZone: .gmt)
        == "会议-20261128-0630.txt")
    #expect(ExportFormat.allCases.map(\.fileExtension) == ["txt", "md"])
    // Without entries the text is just the header.
    #expect(TranscriptExport.render(conversationDocument, as: .text)
        == "面对面对话 2026-11-28 14:30\n语言：中文 ↔ 韩语\n")
}

@MainActor @Test func previewFallsBackToTheOriginal() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    func preview(_ lines: [Line]) throws -> String {
        TranscriptDocument(meeting: try meeting(in: container, lasting: nil, lines),
                           timeZone: shanghai).preview
    }
    #expect(try preview([("One.", "一。", 0, .translated), ("Two.", "二。", 1, .translated)]) == "一。")
    #expect(try preview([("One.", nil, 0, .pendingTranslation)]) == "One.")
    #expect(try preview([("One.", nil, 0, .translationFailed)]) == "One.")
    #expect(try preview([("", nil, 0, .interruptionMarker)]) == "（录音中断）")
    #expect(try preview([]) == "")
    let failed = try conversation(in: container, [(.chinese, "你好。", nil, 0)])
    #expect(TranscriptDocument(conversation: failed, timeZone: shanghai).preview == "你好。")
    #expect(try preview([("One.", "", 0, .translated)]) == "One.")
    let dropped = try conversation(in: container, [(.chinese, "走了。", "", 0)])
    #expect(TranscriptDocument(conversation: dropped, timeZone: shanghai).preview == "走了。")
}
