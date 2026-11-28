import MeetingCore
import SwiftUI

/// The face-to-face page: the pack screen until all four packs are there, then the two halves.
///
/// The model is made once, in `onAppear`, and kept in `@State`: a re-render of this view or of
/// its parent never makes another one. `onDisappear` closes its visit; the closed visit stays in
/// the model, so a page that appears again refreshes its packs. What depends on the partner
/// language carries `.id(partner)`: a change drops its view state and runs `refresh()` again.
/// Actions read `model.visit` when they happen, as a change replaces it. The modifiers sit on
/// `ZStack`s, not on a `Group` or a bare `if`: those hand them to each branch, and a branch
/// switch would then end the visit, or run `refresh()` again from `ready`.
struct FaceToFacePage: View {
    let makeModel: @MainActor () -> FaceToFaceModel
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: FaceToFaceModel?
    /// The side whose turn was started last: where the session's notice belongs.
    @State private var lastSpeaker = ConversationSide.chinese

    var body: some View {
        ZStack {
            Color.clear
            if let model { content(model) }
        }
        // Not a constant `true`: the page left behind restores the system default when it
        // disappears, which may be after this one appeared. The model arrives after that.
        .keepScreenAwake(model != nil)
        .onAppear { if model == nil { model = makeModel() } }
        .onDisappear { model?.close() }
        .onChange(of: model?.visit.partner) { lastSpeaker = .chinese }
        // `.inactive` (Control Centre, a notification, the permission prompt) changes nothing.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model?.visit.session.enterBackground()
            case .active: model?.visit.session.enterForeground()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private func content(_ model: FaceToFaceModel) -> some View {
        let visit = model.visit
        let picker = PartnerPicker(partner: visit.partner, canChoose: model.canChoose,
                                   choose: { model.choose($0) })
        return ZStack {
            if visit.packs.step == .ready {
                let session = visit.session
                ConversationBoard(
                    picker: picker, phase: session.phase, liveText: session.liveText,
                    utterances: session.utterances, notice: session.notice,
                    saveFailed: session.saveFailed, lastSpeaker: lastSpeaker,
                    tap: { tap($0, model) }, close: onClose)
            } else {
                ConversationPacksView(
                    packs: visit.packs, picker: picker,
                    isCurrent: { visit.packs === model.visit.packs }, close: onClose)
            }
        }
        .conversationTranslationDownload(for: visit.packs)
        .task { await model.visit.packs.refresh() }
        .id(visit.partner)
    }

    private func tap(_ side: ConversationSide, _ model: FaceToFaceModel) {
        let session = model.visit.session
        Task {
            // The language may have changed before this task ran: the tap was on the old board,
            // and a closed visit's session would still record.
            guard session === model.visit.session else { return }
            // Checked and recorded with no suspension before `tap` begins the turn.
            if session.phase == .idle { lastSpeaker = side }
            await session.tap(side)
        }
    }
}
