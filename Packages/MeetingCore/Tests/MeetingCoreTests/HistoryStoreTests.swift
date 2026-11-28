import Testing
import Foundation
import SwiftData
@testable import MeetingCore

// History task 1: SchemaV2 adds face-to-face conversations; records can be deleted.

private let enUS = Locale(identifier: "en-US")
private let began = Date(timeIntervalSince1970: 1_700_000_000)

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// What is in the store itself, as a new context on the same container sees it.
@MainActor private func stored<T: PersistentModel>(_ type: T.Type,
                                                   in container: ModelContainer) throws -> [T] {
    try ModelContext(container).fetch(FetchDescriptor<T>())
}

/// A meeting with one translated and one pending sentence.
@MainActor private func makeMeeting(_ store: TranscriptStore, _ texts: [String]) throws
    -> (meeting: UUID, segments: [UUID]) {
    let meeting = try store.startMeeting(locale: enUS, at: began)
    let segments = try texts.enumerated().map { offset, text in
        try store.append(Sentence(text: text, start: Double(offset), end: Double(offset + 1)),
                         to: meeting)
    }
    try store.setTranslation("译：\(texts[0])", for: segments[0])
    return (meeting, segments)
}

@MainActor private func makeConversation(_ store: TranscriptStore, _ texts: [String]) throws -> UUID {
    let conversation = try store.startConversation(languageCodes: ["zh", "ko"], at: began)
    for text in texts {
        _ = try store.appendTurn(speakerCode: ConversationSide.allCases[0].rawValue,
                                 original: text, translation: nil, at: began, to: conversation)
    }
    return conversation
}

// MARK: - Migration

/// Records written by the shipped app (schema 1.0.0) are all there after the store is opened
/// with schema 2.0.0, and the migrated store accepts conversations.
@MainActor @Test func v1StoreOpensUnderV2WithItsMeetingsIntact() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("transcripts.store")

    let meetingID: UUID
    let title: String
    do {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let v1 = try ModelContainer(for: schema,
                                    configurations: ModelConfiguration(schema: schema, url: url))
        let store = TranscriptStore(container: v1)
        meetingID = try makeMeeting(store, ["One.", "Two."]).meeting
        title = try #require(try v1.mainContext.fetch(FetchDescriptor<Meeting>()).first).title
    }

    let container = try MeetingStorage.makeContainer(at: url)
    #expect(container.schema.version == Schema.Version(2, 0, 0))
    let store = TranscriptStore(container: container)
    let meetings = try container.mainContext.fetch(FetchDescriptor<Meeting>())
    #expect(meetings.map(\.id) == [meetingID])
    #expect(meetings.map(\.title) == [title])
    let segments = try store.segments(of: meetingID)
    #expect(segments.map(\.sourceText) == ["One.", "Two."])
    #expect(segments.map(\.translatedText) == ["译：One.", nil])
    #expect(segments.map(\.index) == [0, 1])

    let conversation = try makeConversation(store, ["你好"])
    #expect(try store.turns(of: conversation).map(\.original) == ["你好"])
    #expect(try stored(ConversationTurnRecord.self, in: container).map(\.original) == ["你好"])
}

// MARK: - Conversations

@MainActor @Test func appendTurnKeepsOrderAndSurvivesAFreshContext() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let conversation = try store.startConversation(languageCodes: ["zh", "ko"], at: began)
    let first = try store.appendTurn(speakerCode: "a", original: "你好", translation: "안녕하세요",
                                     at: began, to: conversation)
    let second = try store.appendTurn(speakerCode: "b", original: "반갑습니다", translation: nil,
                                      at: began.addingTimeInterval(5), to: conversation)
    let third = try store.appendTurn(speakerCode: "a", original: "再见", translation: "안녕",
                                     at: began.addingTimeInterval(9), to: conversation)

    let turns = try store.turns(of: conversation)
    #expect(turns.map(\.id) == [first, second, third])
    #expect(turns.map(\.index) == [0, 1, 2])

    let fresh = try ModelContext(container).fetch(
        FetchDescriptor<ConversationTurnRecord>(sortBy: [SortDescriptor(\.index)]))
    #expect(fresh.map(\.id) == [first, second, third])
    #expect(fresh.map(\.speakerCode) == ["a", "b", "a"])
    #expect(fresh.map(\.original) == ["你好", "반갑습니다", "再见"])
    #expect(fresh.map(\.translation) == ["안녕하세요", nil, "안녕"])
    #expect(fresh.map(\.date) == [0.0, 5, 9].map { began.addingTimeInterval($0) })
    #expect(fresh.allSatisfy { $0.conversation?.id == conversation })

    let records = try stored(ConversationRecord.self, in: container)
    #expect(records.map(\.id) == [conversation])
    #expect(records.map(\.startedAt) == [began])
    #expect(records.map(\.languageCodes) == [["zh", "ko"]])
}

@MainActor @Test func unknownConversationThrowsConversationNotFound() throws {
    let store = try TranscriptStore.inMemory()
    let unknown = UUID()
    let expected = TranscriptStore.StoreError.conversationNotFound(unknown)
    #expect(throws: expected) {
        try store.appendTurn(speakerCode: "a", original: "x", translation: nil,
                             at: began, to: unknown)
    }
    #expect(throws: expected) { try store.turns(of: unknown) }
}

@MainActor @Test func failedConversationWritesAreRolledBack() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)

    store.failNextSaves = 1
    #expect(throws: (any Error).self) {
        try store.startConversation(languageCodes: ["zh", "ko"], at: began)
    }
    #expect(try stored(ConversationRecord.self, in: container).isEmpty)

    let conversation = try makeConversation(store, ["一"])
    store.failNextSaves = 1
    #expect(throws: (any Error).self) {
        try store.appendTurn(speakerCode: "a", original: "lost", translation: nil,
                             at: began, to: conversation)
    }
    _ = try store.appendTurn(speakerCode: "a", original: "二", translation: nil,
                             at: began, to: conversation)
    #expect(try store.turns(of: conversation).map(\.original) == ["一", "二"])
    #expect(try store.turns(of: conversation).map(\.index) == [0, 1])
    #expect(try stored(ConversationTurnRecord.self, in: container).count == 2)
}

// MARK: - Delete

/// Deleted from a newly opened on-disk store, so the cascade runs on relationships that
/// were never loaded.
@MainActor @Test func deleteMeetingRemovesItsSegmentsOnly() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("transcripts.store")

    let doomed: UUID, kept: UUID, conversation: UUID
    do {
        let store = TranscriptStore(container: try MeetingStorage.makeContainer(at: url))
        doomed = try makeMeeting(store, ["Gone one.", "Gone two."]).meeting
        kept = try makeMeeting(store, ["Kept one.", "Kept two."]).meeting
        conversation = try makeConversation(store, ["你好"])
    }

    let container = try MeetingStorage.makeContainer(at: url)
    try TranscriptStore(container: container).deleteMeeting(doomed)

    #expect(!container.mainContext.hasChanges)
    #expect(try stored(Meeting.self, in: container).map(\.id) == [kept])
    #expect(try stored(Segment.self, in: container).map(\.sourceText).sorted()
            == ["Kept one.", "Kept two."])
    #expect(try stored(ConversationRecord.self, in: container).map(\.id) == [conversation])
    #expect(try stored(ConversationTurnRecord.self, in: container).count == 1)
}

@MainActor @Test func deleteConversationRemovesItsTurnsOnly() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("transcripts.store")

    let doomed: UUID, kept: UUID, meeting: UUID
    do {
        let store = TranscriptStore(container: try MeetingStorage.makeContainer(at: url))
        doomed = try makeConversation(store, ["删一", "删二"])
        kept = try makeConversation(store, ["留一", "留二"])
        meeting = try makeMeeting(store, ["One."]).meeting
    }

    let container = try MeetingStorage.makeContainer(at: url)
    try TranscriptStore(container: container).deleteConversation(doomed)

    #expect(!container.mainContext.hasChanges)
    #expect(try stored(ConversationRecord.self, in: container).map(\.id) == [kept])
    #expect(try stored(ConversationTurnRecord.self, in: container).map(\.original).sorted()
            == ["留一", "留二"].sorted())
    #expect(try stored(Meeting.self, in: container).map(\.id) == [meeting])
    #expect(try stored(Segment.self, in: container).map(\.sourceText) == ["One."])
}

@MainActor @Test func deletingUnknownIDThrows() throws {
    let store = try TranscriptStore.inMemory()
    let meeting = try makeMeeting(store, ["One."]).meeting
    let conversation = try makeConversation(store, ["一"])
    // An id of the other kind is unknown too.
    for id in [UUID(), conversation] {
        #expect(throws: TranscriptStore.StoreError.meetingNotFound(id)) {
            try store.deleteMeeting(id)
        }
    }
    for id in [UUID(), meeting] {
        #expect(throws: TranscriptStore.StoreError.conversationNotFound(id)) {
            try store.deleteConversation(id)
        }
    }
    #expect(try store.segments(of: meeting).count == 1)
    #expect(try store.turns(of: conversation).count == 1)
}

@MainActor @Test func failedDeleteIsRolledBack() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let meeting = try makeMeeting(store, ["One.", "Two."]).meeting
    let conversation = try makeConversation(store, ["一", "二"])

    store.failNextSaves = 2
    #expect(throws: TranscriptStore.InjectedSaveFailure.self) { try store.deleteMeeting(meeting) }
    #expect(throws: TranscriptStore.InjectedSaveFailure.self) {
        try store.deleteConversation(conversation)
    }
    #expect(!container.mainContext.hasChanges)
    #expect(try store.segments(of: meeting).map(\.sourceText) == ["One.", "Two."])
    #expect(try store.turns(of: conversation).map(\.original) == ["一", "二"])

    // The next successful save must not carry either failed delete to disk.
    _ = try store.startConversation(languageCodes: ["zh", "ko"], at: began)
    #expect(try stored(Meeting.self, in: container).map(\.id) == [meeting])
    #expect(try stored(Segment.self, in: container).count == 2)
    #expect(try stored(ConversationRecord.self, in: container).count == 2)
    #expect(try stored(ConversationTurnRecord.self, in: container).count == 2)
}

/// A real `save()` failure (a container that does not allow saving), not the injected one:
/// by then SwiftData has processed the delete, and the records must still come back to the
/// main context, which the UI reads.
@MainActor @Test func deleteThatCannotBeSavedLeavesTheRecordsVisible() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("transcripts.store")
    let meeting: UUID, conversation: UUID
    do {
        let store = TranscriptStore(container: try MeetingStorage.makeContainer(at: url))
        meeting = try makeMeeting(store, ["One.", "Two."]).meeting
        conversation = try makeConversation(store, ["一", "二"])
    }

    let schema = Schema(versionedSchema: SchemaV2.self)
    let readOnly = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(schema: schema, url: url, allowsSave: false))
    let store = TranscriptStore(container: readOnly)
    let ui = readOnly.mainContext

    #expect(throws: (any Error).self) { try store.deleteMeeting(meeting) }
    #expect(try ui.fetch(FetchDescriptor<Meeting>()).map(\.id) == [meeting])
    #expect(try ui.fetch(FetchDescriptor<Segment>()).count == 2)
    #expect(try store.segments(of: meeting).map(\.sourceText) == ["One.", "Two."])

    #expect(throws: (any Error).self) { try store.deleteConversation(conversation) }
    #expect(try ui.fetch(FetchDescriptor<ConversationRecord>()).map(\.id) == [conversation])
    #expect(try ui.fetch(FetchDescriptor<ConversationTurnRecord>()).count == 2)
    #expect(try store.turns(of: conversation).map(\.original) == ["一", "二"])
    #expect(!ui.hasChanges)
}

/// A translation can still arrive after its meeting was deleted from the history.
@MainActor @Test func translationForADeletedSegmentThrowsSegmentNotFound() throws {
    let store = try TranscriptStore.inMemory()
    let (meeting, segments) = try makeMeeting(store, ["One.", "Two."])
    try store.deleteMeeting(meeting)
    let pending = segments[1]
    #expect(throws: TranscriptStore.StoreError.segmentNotFound(pending)) {
        try store.setTranslation("二。", for: pending)
    }
    #expect(throws: TranscriptStore.StoreError.segmentNotFound(pending)) {
        try store.markTranslationFailed(pending)
    }
}
