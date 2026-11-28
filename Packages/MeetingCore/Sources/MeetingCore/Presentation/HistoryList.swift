import Foundation

/// Which saved record a history row or detail page is about.
public enum HistoryRecordID: Hashable, Sendable {
    case meeting(UUID)
    case conversation(UUID)
}

/// One row of the history: the record's id and a copy of its texts. A value, so a page that
/// holds one never reads the `@Model` object again, and still works after it is deleted.
public struct HistoryItem: Identifiable, Hashable, Sendable {
    public let id: HistoryRecordID
    public let document: TranscriptDocument

    public init(id: HistoryRecordID, document: TranscriptDocument) {
        self.id = id
        self.document = document
    }
}

/// What the history page lists.
public enum HistoryList {
    /// Meetings and conversations together, newest first; a record without any sentence or
    /// turn is left out. Equal start times keep meetings before conversations, each in the
    /// order given.
    @MainActor public static func items(meetings: [Meeting], conversations: [ConversationRecord],
                                        timeZone: TimeZone = .current) -> [HistoryItem] {
        let meetingItems = meetings.filter { !$0.segments.isEmpty }.map {
            HistoryItem(id: .meeting($0.id), document: TranscriptDocument(meeting: $0, timeZone: timeZone))
        }
        let conversationItems = conversations.filter { !$0.turns.isEmpty }.map {
            HistoryItem(id: .conversation($0.id),
                        document: TranscriptDocument(conversation: $0, timeZone: timeZone))
        }
        let all = meetingItems + conversationItems
        return all.indices.sorted { a, b in
            let (first, second) = (all[a].document.startedAt, all[b].document.startedAt)
            return first != second ? first > second : a < b
        }.map { all[$0] }
    }

    /// The list row's type label.
    public static func kindName(_ kind: TranscriptDocument.Kind) -> String {
        switch kind {
        case .meeting: "会议"
        case .conversation: "对话"
        }
    }
}

extension TranscriptStore {
    /// Deletes the record with everything in it. On failure nothing is deleted.
    public func delete(_ record: HistoryRecordID) throws {
        switch record {
        case .meeting(let id): try deleteMeeting(id)
        case .conversation(let id): try deleteConversation(id)
        }
    }
}
