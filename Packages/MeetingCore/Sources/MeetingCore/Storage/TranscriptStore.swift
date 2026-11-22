import Foundation
import SwiftData

/// 会议记录存储。每个写方法立即 save，已定稿句子不会因崩溃丢失。
///
/// The store reads and writes through `container.mainContext`, the context SwiftUI `@Query`
/// reads, so the UI sees every write at once without cross-context merging. The `@Model`
/// objects it returns belong to that context: use them on the main actor only.
///
/// Autosave: the store never relies on `mainContext.autosaveEnabled` and leaves it as the
/// container's owner set it. Each write saves before it returns and, on failure, rolls back
/// before it returns, all within one main-actor call, so autosave never sees a write's
/// changes pending and can neither persist a failed write nor be needed for a good one.
///
/// The container should come from `MeetingStorage`, which pins the schema (`SchemaV1`).
@MainActor public final class TranscriptStore {
    public enum StoreError: Error, Equatable {
        case meetingNotFound(UUID)
        case segmentNotFound(UUID)
    }

    /// Kept so the container outlives the store: unlike `ModelContext(container)`, its
    /// `mainContext` does not keep the container alive, and using it after the container
    /// is gone crashes (`inMemory()` would otherwise drop its container at once).
    private let container: ModelContainer
    private let context: ModelContext

    /// Test-only seam: while > 0, each write fails right before `save()` (after its changes
    /// are made), as a real save failure would. Not part of the public API.
    var failNextSaves = 0
    struct InjectedSaveFailure: Error {}

    /// Uses `container.mainContext`. Several stores on one container share that context.
    public init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    /// A store on a new in-memory container from `MeetingStorage` (tests, previews).
    public static func inMemory() throws -> TranscriptStore {
        TranscriptStore(container: try MeetingStorage.makeInMemoryContainer())
    }

    public func startMeeting(locale: Locale, at date: Date) throws -> UUID {
        let meeting = Meeting(title: Self.defaultTitle(for: date), startedAt: date,
                              sourceLocaleID: locale.identifier)
        context.insert(meeting)
        try save()
        return meeting.id
    }

    public func append(_ sentence: Sentence, to meetingID: UUID) throws -> UUID {
        let meeting = try fetchMeeting(meetingID)
        let next = (meeting.segments.map(\.index).max() ?? -1) + 1
        let segment = Segment(index: next, sourceText: sentence.text,
                              startTime: sentence.start, endTime: sentence.end)
        segment.meeting = meeting
        context.insert(segment)
        try save()
        return segment.id
    }

    public func setTranslation(_ text: String, for segmentID: UUID) throws {
        let segment = try fetchSegment(segmentID)
        guard segment.statusRaw != SegmentStatus.translated.rawValue else { return }
        segment.translatedText = text
        segment.statusRaw = SegmentStatus.translated.rawValue
        try save()
    }

    public func markTranslationFailed(_ segmentID: UUID) throws {
        let segment = try fetchSegment(segmentID)
        guard segment.statusRaw != SegmentStatus.translated.rawValue else { return }
        segment.statusRaw = SegmentStatus.translationFailed.rawValue
        try save()
    }

    public func endMeeting(_ meetingID: UUID, at date: Date) throws {
        let meeting = try fetchMeeting(meetingID)
        meeting.endedAt = date
        try save()
    }

    public func segments(of meetingID: UUID) throws -> [Segment] {
        try fetchMeeting(meetingID).segments.sorted { $0.index < $1.index }
    }

    /// Every write saves at once, so the only pending changes are the current write's. On a
    /// failure they are rolled back: a retry must not find (and later persist) a half-written
    /// copy, and one bad object must not make every later save fail. The rollback is on the
    /// main context, so it would also drop someone else's unsaved main-context edits; nothing
    /// else edits it (the UI only reads), and the store's own writes are never left pending.
    private func save() throws {
        do {
            if failNextSaves > 0 {
                failNextSaves -= 1
                throw InjectedSaveFailure()
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func fetchMeeting(_ id: UUID) throws -> Meeting {
        let predicate = #Predicate<Meeting> { $0.id == id }
        guard let meeting = try context.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw StoreError.meetingNotFound(id)
        }
        return meeting
    }

    private func fetchSegment(_ id: UUID) throws -> Segment {
        let predicate = #Predicate<Segment> { $0.id == id }
        guard let segment = try context.fetch(FetchDescriptor(predicate: predicate)).first else {
            throw StoreError.segmentNotFound(id)
        }
        return segment
    }

    private static func defaultTitle(for date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.colon)
            .dateTimeSeparator(.space))
    }
}
