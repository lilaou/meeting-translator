import MeetingCore
import SwiftUI

/// What one visit to the face-to-face screen owns.
@MainActor
struct FaceToFaceVisit {
    let session: ConversationSession
    let packs: ConversationPacks

    /// Never waits, so closing the page always works: `leave()` can take arbitrarily long (an
    /// audio start that never returns) and runs on in a task of its own.
    func close() {
        packs.cancel()
        Task { [session] in await session.leave() }
    }
}

/// The face-to-face page: the pack screen until all four packs are there, then the two halves.
///
/// The visit is made once, in `onAppear`, and kept in `@State`: a re-render of this view or of
/// its parent never makes another session. `onDisappear` ends it. The modifiers sit on `ZStack`s,
/// not on a `Group` or a bare `if`: those hand them to each branch, and a branch switch would
/// then end the visit, or run `refresh()` again from `ready`.
struct FaceToFacePage: View {
    let makeVisit: @MainActor () -> FaceToFaceVisit
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var visit: FaceToFaceVisit?
    /// The side whose turn was started last: where the session's notice belongs.
    @State private var lastSpeaker = ConversationSide.chinese

    var body: some View {
        ZStack {
            Color.clear
            if let visit {
                ZStack { content(visit) }
                    .conversationTranslationDownload(for: visit.packs)
                    .task { await visit.packs.refresh() }
            }
        }
        // Not a constant `true`: the page left behind restores the system default when it
        // disappears, which may be after this one appeared. The visit arrives after that.
        .keepScreenAwake(visit != nil)
        .onAppear { if visit == nil { visit = makeVisit() } }
        .onDisappear { visit?.close() }
        // `.inactive` (Control Centre, a notification, the permission prompt) changes nothing.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: visit?.session.enterBackground()
            case .active: visit?.session.enterForeground()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    @ViewBuilder private func content(_ visit: FaceToFaceVisit) -> some View {
        if visit.packs.step == .ready {
            let session = visit.session
            ConversationBoard(
                phase: session.phase, liveText: session.liveText, utterances: session.utterances,
                notice: session.notice, saveFailed: session.saveFailed, lastSpeaker: lastSpeaker,
                tap: { tap($0, session) }, close: onClose)
        } else {
            ConversationPacksView(packs: visit.packs, close: onClose)
        }
    }

    private func tap(_ side: ConversationSide, _ session: ConversationSession) {
        Task {
            // Checked and recorded with no suspension before `tap` begins the turn.
            if session.phase == .idle { lastSpeaker = side }
            await session.tap(side)
        }
    }
}
