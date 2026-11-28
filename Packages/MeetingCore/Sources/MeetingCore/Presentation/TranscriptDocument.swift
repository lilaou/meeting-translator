import Foundation

/// A saved record as the history shows and exports it: a copy of the stored texts, so it can
/// be used off the main actor and after the record is deleted.
public struct TranscriptDocument: Equatable, Sendable {
    public enum Kind: Sendable { case meeting, conversation }

    /// One sentence of a meeting or one turn of a conversation.
    public struct Entry: Equatable, Sendable {
        /// Time into the meeting ("00:00:05"), or clock time and side ("14:31:02 中文方").
        public let label: String
        public let original: String
        /// The translation or a placeholder for a missing one; empty for an interruption.
        public let translation: String
    }

    public let kind: Kind
    public let title: String
    public let startedAt: Date
    /// Lines under the title: languages, and the duration of a finished meeting.
    public let metadata: [String]
    public let entries: [Entry]

    private static let untranslated = "（未翻译）"

    @MainActor public init(meeting: Meeting, timeZone: TimeZone = .current) {
        kind = .meeting
        startedAt = meeting.startedAt
        title = "会议记录 \(Self.titleTime(meeting.startedAt, in: timeZone))"
        var metadata = ["语言：\(CaptionStrings.direction(from: Locale(identifier: meeting.sourceLocaleID)))"]
        if let endedAt = meeting.endedAt {
            metadata.append("时长：\(CaptionFormatting.elapsedText(since: meeting.startedAt, now: endedAt))")
        }
        self.metadata = metadata
        entries = meeting.segments.sorted { $0.index < $1.index }.map(Self.entry)
    }

    @MainActor public init(conversation: ConversationRecord, timeZone: TimeZone = .current) {
        kind = .conversation
        startedAt = conversation.startedAt
        title = "面对面对话 \(Self.titleTime(conversation.startedAt, in: timeZone))"
        let languages = conversation.languageCodes
            .map { CaptionStrings.languageName(of: Locale(identifier: $0)) }
        metadata = ["语言：\(languages.joined(separator: " ↔ "))"]
        entries = conversation.turns.sorted { $0.index < $1.index }.map { turn in
            let time = TranscriptTime(turn.date, in: timeZone)
            let speaker: String? = switch ConversationSide(rawValue: turn.speakerCode) {
            case .chinese: "中文方"
            case .korean: "韩语方"
            case nil: nil
            }
            return Entry(label: [time.clock, speaker].compactMap { $0 }.joined(separator: " "),
                         original: turn.original,
                         translation: turn.translation ?? CaptionStrings.translationFailed)
        }
    }

    /// The first entry's translation, or its original where there is no translation to show;
    /// empty without entries.
    public var preview: String {
        guard let first = entries.first else { return "" }
        let missing = ["", Self.untranslated, CaptionStrings.translationFailed]
        return missing.contains(first.translation) ? first.original : first.translation
    }

    @MainActor private static func entry(for segment: Segment) -> Entry {
        let label = CaptionFormatting.elapsedText(
            since: Date(timeIntervalSinceReferenceDate: 0),
            now: Date(timeIntervalSinceReferenceDate: segment.startTime))
        let display = SegmentDisplay(segment)
        return switch display.kind {
        case .translated:
            Entry(label: label, original: display.sourceText, translation: display.translationText)
        case .pending:
            Entry(label: label, original: display.sourceText, translation: untranslated)
        case .failed:
            Entry(label: label, original: display.sourceText,
                  translation: CaptionStrings.translationFailed)
        case .interruption:
            Entry(label: label, original: CaptionStrings.interruption, translation: "")
        }
    }

    private static func titleTime(_ date: Date, in timeZone: TimeZone) -> String {
        let time = TranscriptTime(date, in: timeZone)
        return "\(time.year)-\(time.month)-\(time.day) \(time.hour):\(time.minute)"
    }
}

/// The zero-padded Gregorian fields of a date in a time zone, whatever the device's locale
/// and calendar.
struct TranscriptTime {
    let year, month, day, hour, minute, second: String

    var clock: String { "\(hour):\(minute):\(second)" }

    init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: date)
        func padded(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        (year, month, day) = (padded(parts.year), padded(parts.month), padded(parts.day))
        (hour, minute, second) = (padded(parts.hour), padded(parts.minute), padded(parts.second))
    }
}
