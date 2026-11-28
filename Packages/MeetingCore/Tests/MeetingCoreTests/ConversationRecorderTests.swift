import Foundation
import SwiftData
import Testing
@testable import MeetingCore

// History task 2: face-to-face turns are stored as they finish.

private let began = Date(timeIntervalSince1970: 1_700_000_000)

/// One visit to the screen: a session that saves through a recorder, whose clock moves on by a
/// second at every reading.
@MainActor private struct Visit {
    let container: ModelContainer
    let store: TranscriptStore
    let engine = ManualASREngine()
    let session: ConversationSession

    init(translator: ConversationTranslator = ConversationTranslator()) throws {
        container = try MeetingStorage.makeInMemoryContainer()
        store = TranscriptStore(container: container)
        var readings = 0
        let recorder = ConversationRecorder(store: store, now: {
            defer { readings += 1 }
            return began.addingTimeInterval(Double(readings))
        })
        session = makeConversation(engine: engine, translator: translator, saver: recorder)
    }

    /// One whole turn of `side` that recognizes `text` (nothing when nil).
    func say(_ text: String?, as side: ConversationSide) async {
        await session.tap(side)
        if let text { engine.send(.finalized(text: text, range: 0...1)) }
        await session.tap(side)
        await waitUntil { session.phase == .idle }
    }

    // What is in the store itself, as a new context on the same container sees it.
    func records() throws -> [ConversationRecord] {
        try ModelContext(container).fetch(FetchDescriptor<ConversationRecord>())
    }

    func turns() throws -> [ConversationTurnRecord] {
        try ModelContext(container).fetch(
            FetchDescriptor<ConversationTurnRecord>(sortBy: [SortDescriptor(\.index)]))
    }
}

/// A regression hangs until the suite's time limit.
@Suite(.timeLimit(.minutes(1)))
struct ConversationRecorderTests {
    @MainActor @Test func eachFinishedTurnIsStoredInOneRecord() async throws {
        let visit = try Visit()
        await visit.say("你好", as: .chinese)
        await visit.say("안녕", as: .korean)

        let records = try visit.records()
        #expect(records.map(\.languageCodes) == [["zh", "ko"]])
        #expect(records.map(\.startedAt) == [began])
        let turns = try visit.turns()
        #expect(turns.map(\.speakerCode) == ["chinese", "korean"])
        #expect(turns.map(\.original) == ["你好", "안녕"])
        #expect(turns.map(\.translation) == ["译:你好", "译:안녕"])
        #expect(turns.map(\.index) == [0, 1])
        #expect(turns.map(\.date) == [0.0, 1].map { began.addingTimeInterval($0) })
        #expect(turns.allSatisfy { $0.conversation?.id == records.first?.id })
        #expect(!visit.session.saveFailed)
    }

    @MainActor @Test func visitWithoutTextStoresNothing() async throws {
        let visit = try Visit()
        await visit.say(nil, as: .chinese)
        #expect(visit.session.notice == .notHeard)
        await visit.session.leave()
        #expect(try visit.records().isEmpty)
        #expect(try visit.turns().isEmpty)
    }

    @MainActor @Test func failedTranslationStoresTheOriginal() async throws {
        let visit = try Visit(translator: ConversationTranslator(failing: true))
        await visit.say("你好", as: .chinese)
        #expect(try visit.turns().map(\.original) == ["你好"])
        #expect(try visit.turns().map(\.translation) == [nil])
        #expect(!visit.session.saveFailed)
    }

    @MainActor @Test func droppedTurnWithTextIsStoredUntranslated() async throws {
        let gate = Gate()
        let translator = ConversationTranslator(gate: gate)
        let visit = try Visit(translator: translator)
        let s = visit.session

        // Dropped while listening.
        await s.tap(.chinese)
        visit.engine.send(.volatile(text: "走了"))
        await waitUntil { s.liveText == "走了" }
        s.enterBackground()
        s.enterBackground()
        s.enterForeground()
        #expect(s.utterances.isEmpty)
        #expect(try visit.turns().map(\.original) == ["走了"])

        // Dropped while its translation is on the way.
        await s.tap(.korean)
        visit.engine.send(.finalized(text: "안녕", range: 0...1))
        await s.tap(.korean)
        await translator.requested.wait()
        let wrapUp = try #require(s.turn?.wrapUp)
        await s.leave()
        gate.open()
        await wrapUp.value
        await s.leave()
        s.enterBackground()

        #expect(s.utterances.isEmpty)
        #expect(!s.saveFailed)
        #expect(try visit.records().count == 1)
        #expect(try visit.turns().map(\.speakerCode) == ["chinese", "korean"])
        #expect(try visit.turns().map(\.original) == ["走了", "안녕"])
        #expect(try visit.turns().map(\.translation) == ["", ""])
    }

    @MainActor @Test func leaveWhileListeningStoresTheRecognizedText() async throws {
        let visit = try Visit()
        let s = visit.session
        await s.tap(.chinese)
        visit.engine.send(.finalized(text: "你好", range: 0...1))
        await waitUntil { s.liveText == "你好" }
        await s.leave()
        await s.leave()
        #expect(s.utterances.isEmpty)
        #expect(try visit.turns().map(\.original) == ["你好"])
        #expect(try visit.turns().map(\.translation) == [""])
    }

    @MainActor @Test func leaveWhileWaitingForForegroundStoresTheTurnOnce() async throws {
        let translator = ConversationTranslator()
        let visit = try Visit(translator: translator)
        let s = visit.session
        await s.tap(.chinese)
        visit.engine.send(.finalized(text: "等等", range: 0...1))
        await s.tap(.chinese)
        s.enterBackground()                             // finishing: kept, not yet stored
        await waitUntil { s.foregroundSignal != nil }
        #expect(try visit.turns().isEmpty)
        let wrapUp = try #require(s.turn?.wrapUp)
        await s.leave()
        s.enterForeground()
        await wrapUp.value
        #expect(translator.requests.isEmpty)
        #expect(try visit.turns().map(\.original) == ["等等"])
        #expect(try visit.turns().map(\.translation) == [""])
    }

    @MainActor @Test func droppedTurnWithoutTextStoresNothing() async throws {
        let visit = try Visit()
        let s = visit.session
        await s.tap(.chinese)
        s.enterBackground()
        s.enterForeground()
        await s.tap(.korean)
        await s.leave()
        #expect(try visit.records().isEmpty)
        #expect(try visit.turns().isEmpty)
    }

    @MainActor @Test func dropAfterATurnWasAddedStoresItOnlyOnce() async throws {
        let visit = try Visit()
        await visit.say("你好", as: .chinese)
        visit.session.enterBackground()
        visit.session.enterForeground()
        await visit.session.leave()
        #expect(try visit.turns().map(\.translation) == ["译:你好"])
    }

    @MainActor @Test func saveFailureOfADroppedTurnDisturbsNothing() async throws {
        let visit = try Visit()
        let s = visit.session
        await visit.say("一", as: .chinese)
        await s.tap(.korean)
        visit.engine.send(.volatile(text: "丢"))
        await waitUntil { s.liveText == "丢" }
        visit.store.failNextSaves = 1
        s.enterBackground()
        s.enterForeground()
        #expect(s.phase == .idle && s.notice == nil && s.liveText.isEmpty)
        #expect(s.utterances.map(\.original) == ["一"])
        #expect(s.saveFailed)

        await visit.say("二", as: .chinese)
        #expect(!s.saveFailed)
        #expect(try visit.turns().map(\.original) == ["一", "二"])
    }

    /// Also: a failed first write leaves the following turns able to save.
    @MainActor @Test func saveFailureKeepsTheUtteranceAndSetsSaveFailed() async throws {
        let visit = try Visit()
        visit.store.failNextSaves = 1
        await visit.say("你好", as: .chinese)
        #expect(visit.session.saveFailed)
        #expect(visit.session.utterances == [
            .init(id: 0, speaker: .chinese, original: "你好", translation: "译:你好")])
        #expect(visit.session.notice == nil)
        #expect(try visit.records().isEmpty)

        await visit.say("안녕", as: .korean)
        await visit.say("再见", as: .chinese)
        #expect(!visit.session.saveFailed)
        #expect(try visit.records().count == 1)
        #expect(try visit.turns().map(\.original) == ["안녕", "再见"])
    }

    @MainActor @Test func nextTurnClearsSaveFailed() async throws {
        let visit = try Visit()
        await visit.say("一", as: .chinese)
        visit.store.failNextSaves = 1
        await visit.say("丢", as: .chinese)
        #expect(visit.session.saveFailed)

        await visit.session.tap(.korean)
        #expect(visit.session.phase == .listening(.korean))
        #expect(!visit.session.saveFailed)
        visit.engine.send(.finalized(text: "둘", range: 0...1))
        await visit.session.tap(.korean)
        await waitUntil { visit.session.phase == .idle }

        // The turn after a failed append goes into the same record.
        #expect(try visit.records().count == 1)
        #expect(try visit.turns().map(\.original) == ["一", "둘"])
        #expect(try visit.turns().map(\.index) == [0, 1])
    }

    @MainActor @Test func leaveKeepsTheStoredRecord() async throws {
        let visit = try Visit()
        await visit.say("你好", as: .chinese)
        visit.store.failNextSaves = 1
        await visit.say("丢", as: .chinese)
        await visit.session.leave()
        #expect(visit.session.utterances.isEmpty)
        #expect(!visit.session.saveFailed)
        #expect(try visit.records().count == 1)
        #expect(try visit.turns().map(\.original) == ["你好"])
    }
}
