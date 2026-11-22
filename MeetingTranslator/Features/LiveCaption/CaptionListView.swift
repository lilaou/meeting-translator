import MeetingCore
import SwiftData
import SwiftUI

/// The stored captions of ONE meeting. The `Query` is built in `init` from the meeting id, as
/// obligation 5 requires (a `@Query` cannot see a parent's property any other way): filtered
/// by `meeting?.id`, sorted by `index`. Read-only: nothing here inserts, edits or saves.
struct CaptionListView: View {
    @Query private var segments: [Segment]
    let volatileText: String

    init(meetingID: UUID, volatileText: String) {
        _segments = Query(filter: #Predicate<Segment> { $0.meeting?.id == meetingID },
                          sort: \Segment.index)
        self.volatileText = volatileText
    }

    var body: some View {
        CaptionListContent(
            rows: segments.map { CaptionRow(id: $0.id, display: SegmentDisplay($0)) },
            volatileText: volatileText)
    }
}

/// The scrolling list for plain values (used by `CaptionListView` and by previews).
struct CaptionListContent: View {
    let rows: [CaptionRow]
    let volatileText: String
    @State private var follow = ScrollFollowState()
    /// True while a user-driven scroll phase (finger down or flinging) is in progress.
    @State private var userIsScrolling = false

    /// How close to the end still counts as "at the bottom" (points).
    private static let bottomTolerance: CGFloat = 40
    private static let bottomID = "bottom"

    /// Changes when something is added or finishes translating, or the volatile line changes.
    private struct ContentToken: Equatable {
        let rows: [CaptionRow]
        let volatileText: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { SegmentRow(display: $0.display) }
                    if !volatileText.isEmpty {
                        Text(volatileText).font(.title3).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
            }
            // Obligation 13: only the user's own scrolling may change the follow state.
            // Content growth and our own `scrollTo` run in other phases (.idle/.animating),
            // so they never reach `userScrolled`; the bottom check runs only while the user
            // is dragging or flinging.
            .onScrollPhaseChange { _, new in
                userIsScrolling = new == .interacting || new == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.bottomTolerance
            } action: { _, atBottom in
                if userIsScrolling { follow.userScrolled(isAtBottom: atBottom) }
            }
            .onChange(of: ContentToken(rows: rows, volatileText: volatileText)) {
                if follow.shouldScrollOnNewContent { scrollToBottom(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if follow.showsBackToLatest {
                    Button(CaptionStrings.backToLatest) {
                        follow.jumpToLatest()
                        scrollToBottom(proxy)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
        CaptionListView(meetingID: meeting.id, volatileText: "live…").modelContainer(container)
    } else {
        Text("preview container failed")
    }
}
#endif
