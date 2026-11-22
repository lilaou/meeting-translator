import MeetingCore
import SwiftData
import SwiftUI

/// The stored captions of ONE meeting. The `Query` is built in `init` from the meeting id, as
/// obligation 5 requires (a `@Query` cannot see a parent's property any other way): filtered
/// by `meeting?.id`, sorted by `index`. Read-only: nothing here inserts, edits or saves.
/// The live (volatile) line comes in as `tail` and is rendered by `VolatileLine`, which alone
/// observes the coordinator: partial-recognition updates then re-render only that line, never
/// this body (which maps every stored segment).
struct CaptionListView<Tail: View>: View {
    @Query private var segments: [Segment]
    @ViewBuilder let tail: Tail

    init(meetingID: UUID, @ViewBuilder tail: () -> Tail) {
        _segments = Query(filter: #Predicate<Segment> { $0.meeting?.id == meetingID },
                          sort: \Segment.index)
        self.tail = tail()
    }

    var body: some View {
        CaptionListContent(
            rows: segments.map { CaptionRow(id: $0.id, display: SegmentDisplay($0)) }) { tail }
    }
}

/// The current partial recognition; the only view that reads `coordinator.volatileText`.
struct VolatileLine: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        if !coordinator.volatileText.isEmpty {
            Text(coordinator.volatileText).font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension CaptionRow {
    static func sample(_ n: Int, _ status: SegmentStatus = .translated) -> CaptionRow {
        CaptionRow(id: UUID(), display: SegmentDisplay(
            status: status, sourceText: "Sentence number \(n).",
            translatedText: status == .translated ? "第 \(n) 句。" : nil))
    }
}

#Preview("empty") { CaptionListContent(rows: []) { Text("") } }
#Preview("rows and volatile") {
    CaptionListContent(
        rows: (1...3).map { .sample($0) } + [.sample(4, .pendingTranslation),
                                             .sample(5, .translationFailed),
                                             .sample(6, .interruptionMarker)]) {
        Text("and then we should").font(.title3).foregroundStyle(.secondary)
    }
}
#Preview("long, scrolls") { CaptionListContent(rows: (1...40).map { .sample($0) }) { Text("") } }

#if DEBUG
// Preview-only seeding of an IN-MEMORY container. This is NOT product code: product views
// never write to `mainContext` (obligation 3).
@MainActor private func seededContainer() throws -> ModelContainer {
    let container = try MeetingStorage.makeInMemoryContainer()
    let meeting = Meeting(title: "Preview", startedAt: .now, sourceLocaleID: "en-US")
    container.mainContext.insert(meeting)
    for n in 0..<3 {
        let segment = Segment(index: n, sourceText: "Sentence number \(n).", startTime: 0, endTime: 1)
        segment.meeting = meeting
        container.mainContext.insert(segment)
    }
    return container
}

#Preview("@Query list") {
    // Resolved inside the preview body so a failure shows as text rather than crashing.
    if let container = try? seededContainer(), let meeting = try? container.mainContext
        .fetch(FetchDescriptor<Meeting>()).first {
        // A plain `Text` stands in for `VolatileLine`, which needs a real coordinator.
        CaptionListView(meetingID: meeting.id) { Text("live…").foregroundStyle(.secondary) }
            .modelContainer(container)
    } else {
        Text("preview container failed")
    }
}
#endif
