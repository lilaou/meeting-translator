import MeetingCore      // deliberately not @testable: only what the app can see
import Testing

struct ConversationUtteranceTests {
    /// The app's previews build conversation entries from outside the module.
    @Test func anEntryCanBeBuiltThroughThePublicInitializer() {
        let entry = ConversationUtterance(id: 3, speaker: .korean, original: "안녕", translation: "你好")
        #expect(entry.id == 3)
        #expect(entry.speaker == .korean)
        #expect(entry.original == "안녕")
        #expect(entry.translation == "你好")
        let failed = ConversationUtterance(id: 4, speaker: .chinese, original: "好", translation: nil)
        #expect(failed.translation == nil)
    }
}
