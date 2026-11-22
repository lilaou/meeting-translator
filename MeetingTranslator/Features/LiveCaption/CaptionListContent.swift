import MeetingCore
import SwiftUI

/// The scrolling list for plain values (used by `CaptionListView` and by previews). `tail` is
/// the live line after the last row.
struct CaptionListContent<Tail: View>: View {
    let rows: [CaptionRow]
    @ViewBuilder let tail: Tail
    @State private var follow = ScrollFollowState()
    /// True while a user-driven scroll phase (finger down or flinging) is in progress.
    @State private var userIsScrolling = false
    /// Latest "newest caption in view" reading, updated in EVERY phase so the end of a user
    /// gesture can re-read it even if the change happened outside a user phase.
    @State private var isAtBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    /// How close to the end still counts as "at the bottom" (points).
    private static let bottomTolerance: CGFloat = 40

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(rows) { SegmentRow(display: $0.display) }
                tail
            }
            .padding()
        }
        // Only the INITIAL offset starts at the bottom (a list that appears with existing
        // rows); the other roles (.sizeChanges, .alignment) would shift history the user is
        // reading and push a short list's first captions to the bottom of the screen.
        // Bottom scrolling uses `ScrollPosition.scrollTo(edge:)`, which is geometry based,
        // instead of an id anchor after a LazyVStack that may land short from far away.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        // Obligation 13: only the user's own scrolling may change the follow state. Content
        // growth and our own scrolling never call `userScrolled` outside a user gesture.
        // Real phase ordering (including whether a programmatic scroll interrupting a fling
        // is reported as `.animating`) is a device check; see the contracts note.
        .onScrollPhaseChange { _, new in
            switch new {
            case .interacting, .decelerating:
                userIsScrolling = true
            case .tracking:
                break
            case .animating:
                // A programmatic scroll took over (e.g. "回到最新" during a fling): not the
                // user's decision, so no `userScrolled` call.
                userIsScrolling = false
            case .idle:
                if userIsScrolling {
                    userIsScrolling = false
                    follow.userScrolled(isAtBottom: isAtBottom)
                    if follow.shouldScrollOnNewContent { scrollToBottom() }
                }
            @unknown default:
                break
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomTolerance
        } action: { _, atBottom in
            isAtBottom = atBottom
            // Known limit (N4): growth during a gesture at the bottom can flip this to false;
            // listed in the device checklist rather than guessed at here.
            if userIsScrolling { follow.userScrolled(isAtBottom: atBottom) }
        }
        // Any growth of the content (a new row, a translation landing on any row, a wrapping
        // live line) follows the bottom, but never under the user's finger; the end of the
        // gesture catches up.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
            if new > old, follow.shouldScrollOnNewContent, !userIsScrolling { scrollToBottom() }
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
