import MeetingCore
import SwiftData
import SwiftUI

/// The saved meetings and conversations, newest first, each opening its transcript.
///
/// Reads with `@Query` only; deleting goes through `delete` (the app's `TranscriptStore`, the
/// only writer). Rows and the detail page hold `HistoryItem` values, copies of the texts, so
/// nothing reads a deleted `@Model` object. A failed delete is rolled back by the store, so the
/// queries still list the record, and "删除失败" is shown.
///
/// Opened only while no meeting runs (see `AppRoute.showHistory` and its callers), so no record
/// changes while this page is on screen except by a delete from here.
struct HistoryPage: View {
    let delete: @MainActor (HistoryRecordID) throws -> Void
    let onClose: () -> Void

    @Query private var meetings: [Meeting]
    @Query private var conversations: [ConversationRecord]
    @State private var path: [HistoryItem] = []
    /// The row waiting for the user to confirm its deletion.
    @State private var pendingDelete: HistoryItem?
    @State private var deleteFailed = false

    init(delete: @escaping @MainActor (HistoryRecordID) throws -> Void, onClose: @escaping () -> Void) {
        self.delete = delete
        self.onClose = onClose
    }

    var body: some View {
        let items = HistoryList.items(meetings: meetings, conversations: conversations)
        NavigationStack(path: $path) {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "clock",
                                           description: Text("会议和面对面对话结束后会保存在这里。"))
                } else {
                    List(items) { item in
                        NavigationLink(value: item) { HistoryRow(item: item) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Not `role: .destructive`: that removes the row at once,
                                // before the user has confirmed.
                                Button { pendingDelete = item } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
            }
            .navigationDestination(for: HistoryItem.self) { item in
                TranscriptDetailView(item: item, delete: delete)
            }
            .confirmDeletion(of: $pendingDelete) { item in
                do { try delete(item.id) } catch { deleteFailed = true }
            }
            .alert("删除失败", isPresented: $deleteFailed) { Button("好", role: .cancel) {} }
        }
    }
}

/// Type, start time and the first sentence of one record.
private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(HistoryList.kindName(item.document.kind))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(kindTint.opacity(0.2), in: Capsule())
                Text(item.document.startedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(item.document.preview)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var kindTint: Color {
        switch item.document.kind {
        case .meeting: .blue
        case .conversation: .green
        }
    }
}

extension View {
    /// Asks "删除这条记录？删除后无法恢复。" while `item` is set, and runs `confirmed` with it
    /// when the user agrees. Shared by the list and the detail page.
    func confirmDeletion(of item: Binding<HistoryItem?>,
                         confirmed: @escaping (HistoryItem) -> Void) -> some View {
        alert("删除这条记录？", isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), presenting: item.wrappedValue) { pending in
            Button("删除", role: .destructive) { confirmed(pending) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后无法恢复。")
        }
    }
}

#if DEBUG
/// Preview-only: a store on an IN-MEMORY container, filled through the store's own API.
@MainActor func historyPreview() -> (container: ModelContainer, store: TranscriptStore)? {
    guard let container = try? MeetingStorage.makeInMemoryContainer() else { return nil }
    let store = TranscriptStore(container: container)
    let start = Date.now.addingTimeInterval(-3 * 3_600)
    do {
        let meeting = try store.startMeeting(locale: Locale(identifier: "en-US"), at: start)
        let lines = [("Good morning, everyone.", "大家早上好。"),
                     ("Let's review the budget first.", "我们先看一下预算。"),
                     ("The numbers are on the next slide.", nil)]
        for (offset, line) in lines.enumerated() {
            let id = try store.append(Sentence(text: line.0, start: Double(offset * 7),
                                               end: Double(offset * 7 + 5)), to: meeting)
            if let translation = line.1 { try store.setTranslation(translation, for: id) }
        }
        try store.endMeeting(meeting, at: start.addingTimeInterval(1_520))

        let conversation = try store.startConversation(languageCodes: ["zh", "ko"],
                                                       at: start.addingTimeInterval(3_600))
        _ = try store.appendTurn(speakerCode: ConversationSide.chinese.rawValue,
                                 original: "你好，很高兴认识你。", translation: "안녕하세요, 만나서 반갑습니다.",
                                 at: start.addingTimeInterval(3_600), to: conversation)
        _ = try store.appendTurn(speakerCode: ConversationSide.korean.rawValue,
                                 original: "점심 드셨어요?", translation: nil,
                                 at: start.addingTimeInterval(3_630), to: conversation)
        // No sentence: not listed.
        _ = try store.startMeeting(locale: Locale(identifier: "ko-KR"), at: .now)
    } catch {
        return nil
    }
    return (container, store)
}

#Preview("history") {
    if let preview = historyPreview() {
        HistoryPage(delete: { try preview.store.delete($0) }, onClose: {})
            .modelContainer(preview.container)
    } else {
        Text("preview store failed")
    }
}

#Preview("history, empty") {
    if let container = try? MeetingStorage.makeInMemoryContainer() {
        HistoryPage(delete: { _ in }, onClose: {})
            .modelContainer(container)
    } else {
        Text("preview container failed")
    }
}
#endif
