import Foundation
import SwiftData

public enum SegmentStatus: String, Codable, Sendable {
    case pendingTranslation, translated, translationFailed, interruptionMarker
}

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
