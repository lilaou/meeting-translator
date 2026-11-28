import Foundation

/// Keeps the turns of a conversation. `ConversationSession` hands it each turn it adds.
@MainActor public protocol ConversationSaving: AnyObject {
    func save(speaker: ConversationSide, original: String, translation: String?) throws
}

/// Saves one visit to the face-to-face screen as one conversation record: build one per visit.
/// The record is created with the first turn, so a visit without any leaves nothing.
@MainActor public final class ConversationRecorder: ConversationSaving {
    private let store: TranscriptStore
    private let now: () -> Date
    /// Set only once the record is in the store, so a failed creation is tried again with the
    /// next turn.
    private var conversationID: UUID?

    public init(store: TranscriptStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func save(speaker: ConversationSide, original: String, translation: String?) throws {
        let date = now()
        let id = try conversationID ?? store.startConversation(languageCodes: ["zh", "ko"], at: date)
        conversationID = id
        _ = try store.appendTurn(speakerCode: speaker.rawValue, original: original,
                                 translation: translation, at: date, to: id)
    }
}
