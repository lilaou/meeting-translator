import Foundation
import SwiftData

public enum SegmentStatus: String, Codable, Sendable {
    case pendingTranslation, translated, translationFailed, interruptionMarker
}

// Schema: the models here are pinned as `SchemaV2` (version 2.0.0, see MeetingSchema.swift);
// `Meeting` and `Segment` are also the whole of `SchemaV1` (1.0.0), unchanged since. Any
// change to a stored property or relationship needs a new schema version and a stage in
// `MeetingMigrationPlan`; records already on a device must stay readable. The objects belong
// to the main context (see `TranscriptStore`).

@Model public final class Meeting {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var sourceLocaleID: String
    @Relationship(deleteRule: .cascade, inverse: \Segment.meeting)
    public var segments: [Segment] = []

    public init(id: UUID = UUID(), title: String, startedAt: Date, sourceLocaleID: String) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.sourceLocaleID = sourceLocaleID
    }
}

@Model public final class Segment {
    public var id: UUID
    public var meeting: Meeting?
    public var index: Int
    public var sourceText: String
    public var translatedText: String?
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var statusRaw: String

    /// Typed view of `statusRaw`; an unknown raw value reads as `.pendingTranslation`.
    public var status: SegmentStatus { SegmentStatus(rawValue: statusRaw) ?? .pendingTranslation }

    public init(id: UUID = UUID(), index: Int, sourceText: String,
                startTime: TimeInterval, endTime: TimeInterval,
                status: SegmentStatus = .pendingTranslation) {
        self.id = id
        self.index = index
        self.sourceText = sourceText
        self.startTime = startTime
        self.endTime = endTime
        self.statusRaw = status.rawValue
    }
}

/// A saved face-to-face conversation.
@Model public final class ConversationRecord {
    public var id: UUID
    public var startedAt: Date
    public var languageCodes: [String]
    @Relationship(deleteRule: .cascade, inverse: \ConversationTurnRecord.conversation)
    public var turns: [ConversationTurnRecord] = []

    public init(id: UUID = UUID(), startedAt: Date, languageCodes: [String]) {
        self.id = id
        self.startedAt = startedAt
        self.languageCodes = languageCodes
    }
}

/// One thing one side said. `speakerCode` is a `ConversationSide.rawValue`.
@Model public final class ConversationTurnRecord {
    public var id: UUID
    public var conversation: ConversationRecord?
    public var index: Int
    public var speakerCode: String
    public var original: String
    public var translation: String?
    public var date: Date

    public init(id: UUID = UUID(), index: Int, speakerCode: String, original: String,
                translation: String?, date: Date) {
        self.id = id
        self.index = index
        self.speakerCode = speakerCode
        self.original = original
        self.translation = translation
        self.date = date
    }
}

public struct Sentence: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}
