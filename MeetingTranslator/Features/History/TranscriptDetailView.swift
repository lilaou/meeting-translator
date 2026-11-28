import MeetingCore
import SwiftData
import SwiftUI
import UIKit

/// One saved record: its entries, and a menu to share it as a text or Markdown file, copy it
/// or delete it.
///
/// Holds only the `HistoryItem` value it was opened with, never a `@Model` object, so it keeps
/// drawing the same texts while it is popped after its record was deleted.
struct TranscriptDetailView: View {
    let item: HistoryItem
    /// The store's delete (see `HistoryPage`); on success this page closes.
    let delete: @MainActor (HistoryRecordID) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: HistoryItem?
    @State private var deleteFailed = false
    @State private var copied = false

    private var document: TranscriptDocument { item.document }

    var body: some View {
        List {
            Section {
                ForEach(document.metadata, id: \.self) { line in
                    Text(line).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(Array(document.entries.enumerated()), id: \.offset) { _, entry in
                    EntryRow(entry: entry)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .confirmDeletion(of: $pendingDelete) { pending in
            do {
                try delete(pending.id)
                dismiss()
            } catch {
                deleteFailed = true
            }
        }
        .alert("删除失败", isPresented: $deleteFailed) { Button("好", role: .cancel) {} }
        .alert("已复制全文", isPresented: $copied) { Button("好", role: .cancel) {} }
    }

    private var menu: some View {
        Menu {
            share(.text, title: "分享文本文件", systemImage: "doc.plaintext")
            share(.markdown, title: "分享 Markdown 文件", systemImage: "doc.richtext")
            Button {
                UIPasteboard.general.string = TranscriptExport.render(document, as: .text)
                copied = true
            } label: {
                Label("复制全文", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) { pendingDelete = item } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    private func share(_ format: ExportFormat, title: String, systemImage: String) -> some View {
        let file = TranscriptFile(document: document, format: format)
        return ShareLink(item: file, preview: SharePreview(file.fileName)) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Label in small type, the original, and the translation in large type; text can be selected
/// with a long press.
private struct EntryRow: View {
    let entry: TranscriptDocument.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.label)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.original)
                .foregroundStyle(.secondary)
            if !entry.translation.isEmpty {
                Text(entry.translation)
                    .font(.title3)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("meeting") {
    if let preview = historyPreview(),
       let item = previewItem(preview.container, kind: .meeting) {
        NavigationStack {
            TranscriptDetailView(item: item, delete: { try preview.store.delete($0) })
        }
    } else {
        Text("preview store failed")
    }
}

#Preview("conversation") {
    if let preview = historyPreview(),
       let item = previewItem(preview.container, kind: .conversation) {
        NavigationStack {
            TranscriptDetailView(item: item, delete: { try preview.store.delete($0) })
        }
    } else {
        Text("preview store failed")
    }
}

@MainActor private func previewItem(_ container: ModelContainer,
                                    kind: TranscriptDocument.Kind) -> HistoryItem? {
    let context = container.mainContext
    let items = HistoryList.items(meetings: (try? context.fetch(FetchDescriptor<Meeting>())) ?? [],
                                  conversations: (try? context.fetch(
                                      FetchDescriptor<ConversationRecord>())) ?? [])
    return items.first { $0.document.kind == kind }
}
#endif
