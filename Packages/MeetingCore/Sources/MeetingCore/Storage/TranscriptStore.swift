import Foundation
import SwiftData

/// 会议记录存储。每个写方法立即 save，已定稿句子不会因崩溃丢失。
@MainActor public final class TranscriptStore {
    public enum StoreError: Error, Equatable {
        case meetingNotFound(UUID)
        case segmentNotFound(UUID)
    }

    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public static func inMemory() throws -> TranscriptStore {
        let container = try ModelContainer(
            for: Meeting.self, Segment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return TranscriptStore(container: container)
    }

    public func startMeeting(locale: Locale, at date: Date) throws -> UUID {
        let meeting = Meeting(title: Self.defaultTitle(for: date), startedAt: date,
                              sourceLocaleID: locale.identifier)
        context.insert(meeting)
        try context.save()
        return meeting.id
    }

    public func append(_ sentence: Sentence, to meetingID: UUID) throws -> UUID {
        let meeting = try fetchMeeting(meetingID)
        let next = (meeting.segments.map(\.index).max() ?? -1) + 1
        let segment = Segment(index: next, sourceText: sentence.text,
                              startTime: sentence.start, endTime: sentence.end)
        segment.meeting = meeting
        context.insert(segment)
        try context.save()
        return segment.id
    }

    public func setTranslation(_ text: String, for segmentID: UUID) throws {
        let segment = try fetchSegment(segmentID)
        guard segment.statusRaw != SegmentStatus.translated.rawValue else { return }
        segment.translatedText = text
        segment.statusRaw = SegmentStatus.translated.rawValue
        try context.save()
    }

    public func markTranslationFailed(_ segmentID: UUID) throws {
        let segment = try fetchSegment(segmentID)
        guard segment.statusRaw != SegmentStatus.translated.rawValue else { return }
        segment.statusRaw = SegmentStatus.translationFailed.rawValue
        try context.save()
    }

    public func endMeeting(_ meetingID: UUID, at date: Date) throws {
        let meeting = try fetchMeeting(meetingID)
        meeting.endedAt = date
        try context.save()
    }

    public func segments(of meetingID: UUID) throws -> [Segment] {
        try fetchMeeting(meetingID).segments.sorted { $0.index < $1.index }
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
