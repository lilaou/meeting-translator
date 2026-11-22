import MeetingCore
import SwiftData
import SwiftUI

/// The stored captions of ONE meeting. The `Query` is built in `init` from the meeting id, as
/// obligation 5 requires (a `@Query` cannot see a parent's property any other way): filtered
/// by `meeting?.id`, sorted by `index`. Read-only: nothing here inserts, edits or saves.
struct CaptionListView: View {
    @Query private var segments: [Segment]
    /// Read here (not in the parent) so a volatile update re-renders only this view.
    /// Optional so the `@Query` preview can run without a coordinator.
    @Environment(SessionCoordinator.self) private var coordinator: SessionCoordinator?

    init(meetingID: UUID) {
        _segments = Query(filter: #Predicate<Segment> { $0.meeting?.id == meetingID },
                          sort: \Segment.index)
    }

    var body: some View {
        CaptionListContent(
            rows: segments.map { CaptionRow(id: $0.id, display: SegmentDisplay($0)) },
            volatileText: coordinator?.volatileText ?? "")
    }
}

/// The scrolling list for plain values (used by `CaptionListView` and by previews).
struct CaptionListContent: View {
    let rows: [CaptionRow]
    let volatileText: String
    @State private var follow = ScrollFollowState()
    /// True while a user-driven scroll phase (finger down or flinging) is in progress.
    @State private var userIsScrolling = false
    /// Latest "newest caption in view" reading, updated in EVERY phase so the end of a user
    /// gesture can re-read it even if the change happened outside a user phase.
    @State private var isAtBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    /// How close to the end still counts as "at the bottom" (points).
    private static let bottomTolerance: CGFloat = 40

    /// Cheap "something new" signal: row count, the last row, the volatile line.
    private struct ContentToken: Equatable {
        let count: Int
        let last: CaptionRow?
        let volatileText: String
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(rows) { SegmentRow(display: $0.display) }
                if !volatileText.isEmpty {
                    Text(volatileText).font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        // Starts at the bottom when the list appears with existing rows. Bottom scrolling uses
        // `ScrollPosition.scrollTo(edge:)`, which is geometry based, instead of an id anchor
        // after a LazyVStack that may land short when the target is far away and unrealized.
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        // Obligation 13: only the user's own scrolling may change the follow state. Content
        // growth and our own scrolling run in other phases (.idle/.animating), so they never
        // reach `userScrolled`. Real phase ordering is a device check (see the contracts note).
        .onScrollPhaseChange { _, new in
            let wasUser = userIsScrolling
            userIsScrolling = new == .interacting || new == .decelerating
            if wasUser && !userIsScrolling {
                follow.userScrolled(isAtBottom: isAtBottom)
                if follow.shouldScrollOnNewContent { scrollToBottom() }
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomTolerance
        } action: { _, atBottom in
            isAtBottom = atBottom
            if userIsScrolling { follow.userScrolled(isAtBottom: atBottom) }
        }
        .onChange(of: ContentToken(count: rows.count, last: rows.last, volatileText: volatileText)) {
            // Never move the list under the user's finger; the end of the gesture catches up.
            if follow.shouldScrollOnNewContent && !userIsScrolling { scrollToBottom() }
        }
        .overlay(alignment: .bottomTrailing) {
            if follow.showsBackToLatest {
                Button(CaptionStrings.backToLatest) {
                    follow.jumpToLatest()
                    scrollToBottom()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private func scrollToBottom() {
        withAnimation { position.scrollTo(edge: .bottom) }
    }
}

extension CaptionRow {
    static func sample(_ n: Int, _ status: SegmentStatus = .translated) -> CaptionRow {
        CaptionRow(id: UUID(), display: SegmentDisplay(
            status: status, sourceText: "Sentence number \(n).",
            translatedText: status == .translated ? "第 \(n) 句。" : nil))
    }
}

#Preview("empty") { CaptionListContent(rows: [], volatileText: "") }
#Preview("rows and volatile") {
    CaptionListContent(
        rows: (1...3).map { .sample($0) } + [.sample(4, .pendingTranslation),
                                             .sample(5, .translationFailed),
                                             .sample(6, .interruptionMarker)],
        volatileText: "and then we should")
}
#Preview("long, scrolls") { CaptionListContent(rows: (1...40).map { .sample($0) }, volatileText: "") }

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
        CaptionListView(meetingID: meeting.id).modelContainer(container)
    } else {
        Text("preview container failed")
    }
}
#endif
