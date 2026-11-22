import Testing
import Foundation
import SwiftData
@testable import MeetingCore

// Task 11a-1: the store writes on `container.mainContext` (what SwiftUI `@Query` reads), and
// the container is built from a versioned schema through one factory.

private let enUS = Locale(identifier: "en-US")

/// A UI-style read: `@Query` fetches from `container.mainContext`. Without any manual merge
/// it must see a new segment right after `append` and the translation right after
/// `setTranslation`, as the very objects the store handed out.
@MainActor @Test func mainContextFetchSeesEachWriteImmediately() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let ui = container.mainContext
    let m = try store.startMeeting(locale: enUS, at: .now)
    let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)

    let seen = try ui.fetch(FetchDescriptor<Segment>())
    #expect(seen.map(\.sourceText) == ["One."])
    #expect(seen.map(\.id) == [id])
    #expect(!ui.hasChanges)                       // the write was saved, not left pending
    let stored = try #require(try store.segments(of: m).first)
    #expect(seen.first === stored)                // one context: the store's object IS the UI's

    try store.setTranslation("一。", for: id)
    let after = try #require(try ui.fetch(FetchDescriptor<Segment>()).first)
    #expect(after.translatedText == "一。")
    #expect(after.status == .translated)
    #expect(!ui.hasChanges)
}

/// A forced save failure is rolled back on the main context itself: the UI never sees an
/// orphan, and the next successful append takes the index the failed one would have had.
@MainActor @Test func failedAppendIsRolledBackOnTheMainContext() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    let store = TranscriptStore(container: container)
    let ui = container.mainContext
    let m = try store.startMeeting(locale: enUS, at: .now)
    _ = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)

    store.failNextSaves = 1
    #expect(throws: (any Error).self) {
        try store.append(Sentence(text: "Lost.", start: 1, end: 2), to: m)
    }
    #expect(!ui.hasChanges)
    #expect(try ui.fetch(FetchDescriptor<Segment>()).map(\.sourceText) == ["One."])

    _ = try store.append(Sentence(text: "Two.", start: 2, end: 3), to: m)
    let segs = try ui.fetch(FetchDescriptor<Segment>(sortBy: [SortDescriptor(\.index)]))
    #expect(segs.map(\.sourceText) == ["One.", "Two."])
    #expect(segs.map(\.index) == [0, 1])
    let fresh = try ModelContext(container).fetch(FetchDescriptor<Segment>())
    #expect(fresh.map(\.sourceText).sorted() == ["One.", "Two."])
}

/// The store does not rely on autosave: with it off, every write is already in the store
/// (seen from a separate context) when the call returns.
@MainActor @Test func writesAreSavedWithoutAutosave() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    container.mainContext.autosaveEnabled = false
    let store = TranscriptStore(container: container)
    let m = try store.startMeeting(locale: enUS, at: .now)
    let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    try store.setTranslation("一。", for: id)
    try store.endMeeting(m, at: .now)
    let other = ModelContext(container)
    let segs = try other.fetch(FetchDescriptor<Segment>())
    #expect(segs.map(\.translatedText) == ["一。"])
    #expect(try other.fetch(FetchDescriptor<Meeting>()).map { $0.endedAt != nil } == [true])
}

// MARK: - Versioned schema

@Test func schemaIsPinnedAtVersionOne() {
    #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    let models = Set(SchemaV1.models.map { ObjectIdentifier($0) })
    #expect(SchemaV1.models.count == 2)
    #expect(models == [ObjectIdentifier(Meeting.self), ObjectIdentifier(Segment.self)])
    #expect(MeetingMigrationPlan.schemas.map { ObjectIdentifier($0) }
            == [ObjectIdentifier(SchemaV1.self)])
    #expect(MeetingMigrationPlan.stages.isEmpty)
}

@MainActor @Test func factoryContainersUseTheVersionedSchema() throws {
    let container = try MeetingStorage.makeInMemoryContainer()
    #expect(container.schema.version == SchemaV1.versionIdentifier)
    let names = Set(container.schema.entities.map(\.name))
    #expect(names == ["Meeting", "Segment"])
}

/// Snapshot of the stored shape of `SchemaV1`: every attribute and relationship name of both
/// models. Records already on a device were written with this shape, so it must never change.
@MainActor @Test func schemaV1ShapeIsPinned() throws {
    let message: Comment = "a model property changed — add SchemaV2 and a migration stage instead of editing V1"
    let entities = try MeetingStorage.makeInMemoryContainer().schema.entities
    let byName = Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0) })
    let meeting = try #require(byName["Meeting"])
    let segment = try #require(byName["Segment"])
    #expect(Set(meeting.attributes.map(\.name))
            == ["id", "title", "startedAt", "endedAt", "sourceLocaleID"], message)
    #expect(Set(meeting.relationships.map(\.name)) == ["segments"], message)
    #expect(Set(segment.attributes.map(\.name))
            == ["id", "index", "sourceText", "translatedText", "startTime", "endTime", "statusRaw"],
            message)
    #expect(Set(segment.relationships.map(\.name)) == ["meeting"], message)
    // Nothing stored beyond these attributes and relationships.
    #expect(meeting.properties.count == 6, message)
    #expect(segment.properties.count == 8, message)
}

/// Opening the same on-disk store a second time through the factory works, whether the
/// first container is still alive or has been dropped.
@MainActor @Test func onDiskStoreOpensTwiceThroughTheFactory() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("transcripts.store")

    let m: UUID
    do {
        let first = try MeetingStorage.makeContainer(at: url)
        let store = TranscriptStore(container: first)
        m = try store.startMeeting(locale: enUS, at: .now)
        let id = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
        try store.setTranslation("一。", for: id)

        // Container 1 still alive.
        let second = try MeetingStorage.makeContainer(at: url)
        #expect(second.schema.version == SchemaV1.versionIdentifier)
        let whileOpen = try TranscriptStore(container: second).segments(of: m)
        #expect(whileOpen.map(\.sourceText) == ["One."])
        #expect(whileOpen.map(\.translatedText) == ["一。"])
        withExtendedLifetime(store) {}          // container 1 stays open until here
    }

    // Containers 1 and 2 dropped at the end of the scope above.
    let third = try MeetingStorage.makeContainer(at: url)
    let afterDrop = try TranscriptStore(container: third).segments(of: m)
    #expect(afterDrop.map(\.sourceText) == ["One."])
    #expect(afterDrop.map(\.index) == [0])
}
