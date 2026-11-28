import Testing
import Foundation
import SwiftData
@testable import MeetingCore

// History task 4: what the history page lists, deleting by row, and the shared file.

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
/// 2026-11-28 14:30:00 in Asia/Shanghai.
private let began = Date(timeIntervalSince1970: 1_795_847_400)
private let enUS = Locale(identifier: "en-US")

@MainActor private func addMeeting(_ store: TranscriptStore, at date: Date, _ texts: [String]) throws -> UUID {
    let id = try store.startMeeting(locale: enUS, at: date)
    for (offset, text) in texts.enumerated() {
        _ = try store.append(Sentence(text: text, start: Double(offset), end: Double(offset + 1)), to: id)
    }
    return id
}

@MainActor private func addConversation(_ store: TranscriptStore, at date: Date, _ texts: [String]) throws -> UUID {
    let id = try store.startConversation(languageCodes: ["zh", "ko"], at: date)
    for text in texts {
        _ = try store.appendTurn(speakerCode: ConversationSide.chinese.rawValue, original: text,
                                 translation: "译\(text)", at: date, to: id)
    }
    return id
}

@MainActor private func all<T: PersistentModel>(_ type: T.Type, _ container: ModelContainer) throws -> [T] {
    try container.mainContext.fetch(FetchDescriptor<T>())
}

@MainActor @Test func historyListsBothKindsNewestFirstAndSkipsEmptyRecords() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let old = try addMeeting(store, at: began, ["Old meeting."])
    let newer = try addConversation(store, at: began.addingTimeInterval(60), ["你好"])
    let newest = try addMeeting(store, at: began.addingTimeInterval(120), ["New meeting."])
    _ = try addMeeting(store, at: began.addingTimeInterval(180), [])
    _ = try addConversation(store, at: began.addingTimeInterval(240), [])

    let items = HistoryList.items(meetings: try all(Meeting.self, container),
                                  conversations: try all(ConversationRecord.self, container),
                                  timeZone: shanghai)

    #expect(items.map(\.id) == [.meeting(newest), .conversation(newer), .meeting(old)])
    #expect(items.map(\.document.preview) == ["New meeting.", "译你好", "Old meeting."])
    #expect(items.map { HistoryList.kindName($0.document.kind) } == ["会议", "对话", "会议"])
}

@MainActor @Test func historyWithNothingSavedIsEmpty() throws {
    #expect(HistoryList.items(meetings: [], conversations: []).isEmpty)
}

/// Equal start times keep a stable order, so rows never swap between renders.
@MainActor @Test func historyOrderOfEqualStartTimesIsStable() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let meeting = try addMeeting(store, at: began, ["A."])
    let conversation = try addConversation(store, at: began, ["B"])
    let items = HistoryList.items(meetings: try all(Meeting.self, container),
                                  conversations: try all(ConversationRecord.self, container))
    #expect(items.map(\.id) == [.meeting(meeting), .conversation(conversation)])
}

@MainActor @Test func deletingARowRemovesOnlyThatRecord() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let meeting = try addMeeting(store, at: began, ["A.", "B."])
    let conversation = try addConversation(store, at: began, ["C"])

    try store.delete(.meeting(meeting))
    #expect(try all(Meeting.self, container).isEmpty)
    #expect(try all(Segment.self, container).isEmpty)
    #expect(try all(ConversationRecord.self, container).map(\.id) == [conversation])

    try store.delete(.conversation(conversation))
    #expect(try all(ConversationRecord.self, container).isEmpty)
    #expect(try all(ConversationTurnRecord.self, container).isEmpty)
}

/// A failed delete leaves the record in what the history page reads.
@MainActor @Test func failedRowDeleteKeepsTheRecordListed() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let meeting = try addMeeting(store, at: began, ["A."])
    store.failNextSaves = 1

    #expect(throws: (any Error).self) { try store.delete(.meeting(meeting)) }

    let items = HistoryList.items(meetings: try all(Meeting.self, container),
                                  conversations: try all(ConversationRecord.self, container))
    #expect(items.map(\.id) == [.meeting(meeting)])
}

/// A detail page's copy outlives the record.
@MainActor @Test func historyItemStaysUsableAfterItsRecordIsDeleted() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let meeting = try addMeeting(store, at: began, ["Kept in the copy."])
    let item = try #require(HistoryList.items(meetings: try all(Meeting.self, container),
                                              conversations: []).first)
    try store.delete(item.id)
    #expect(try all(Meeting.self, container).isEmpty)
    #expect(item.id == .meeting(meeting))
    #expect(TranscriptExport.render(item.document, as: .text).contains("Kept in the copy."))
}

@MainActor @Test func writtenFileHasTheExportNameAndContent() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    _ = try addMeeting(store, at: began, ["Hello."])
    let document = try #require(HistoryList.items(meetings: try all(Meeting.self, container),
                                                  conversations: [], timeZone: shanghai).first).document
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryListTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for format in ExportFormat.allCases {
        let first = try TranscriptExport.writeFile(document, as: format, in: dir, timeZone: shanghai)
        let second = try TranscriptExport.writeFile(document, as: format, in: dir, timeZone: shanghai)
        #expect(first.lastPathComponent == "会议-20261128-1430.\(format.fileExtension)")
        #expect(first.pathExtension == format.fileExtension)
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8)
                == TranscriptExport.render(document, as: format))
        #expect(try String(contentsOf: second, encoding: .utf8)
                == TranscriptExport.render(document, as: format))
    }
}

/// Exported files hold record texts, so they live in one folder that can be removed as a whole.
@MainActor @Test func removingExportedFilesDeletesOnlyTheExportFolder() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    _ = try addMeeting(store, at: began, ["Hello."])
    let document = try #require(HistoryList.items(meetings: try all(Meeting.self, container),
                                                  conversations: []).first).document
    let files = FileManager.default
    let dir = files.temporaryDirectory
        .appendingPathComponent("HistoryListTests-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: dir) }
    let other = dir.appendingPathComponent("other.txt", isDirectory: false)
    try Data("x".utf8).write(to: other)

    TranscriptExport.removeExportedFiles(in: dir)               // nothing exported yet
    let first = try TranscriptExport.writeFile(document, as: .text, in: dir)
    let second = try TranscriptExport.writeFile(document, as: .markdown, in: dir)
    #expect(try files.contentsOfDirectory(atPath: dir.path).sorted()
            == [TranscriptExport.folderName, "other.txt"].sorted())
    #expect([first, second].allSatisfy {
        $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            == TranscriptExport.folderName
    })

    TranscriptExport.removeExportedFiles(in: dir)
    TranscriptExport.removeExportedFiles(in: dir)
    #expect(try files.contentsOfDirectory(atPath: dir.path) == ["other.txt"])
    // The next export makes the folder again.
    let again = try TranscriptExport.writeFile(document, as: .text, in: dir)
    #expect(files.fileExists(atPath: again.path))
}
