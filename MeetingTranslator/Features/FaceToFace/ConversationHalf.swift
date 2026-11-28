import MeetingCore
import SwiftUI

/// One side's view of the conversation, in that side's language only: every entry, what is
/// being said, and the side's button. The newest is at the bottom.
struct ConversationHalf: View {
    let side: ConversationSide
    let phase: ConversationSession.Phase
    let liveText: String
    let utterances: [ConversationUtterance]
    /// Already chosen for this side (see `Notice.shown`).
    let notice: ConversationShownNotice?
    /// Shows "这条对话没有保存" under the latest turn.
    let saveFailed: Bool
    let tap: () -> Void
    /// The close button; only the lower half has it, and it is never disabled.
    let close: (() -> Void)?
    /// At the top; only the lower half has it.
    let picker: PartnerPicker?
    @State private var position = ScrollPosition(edge: .bottom)

    private var texts: HalfTexts { HalfTexts(side) }
    private var isSpeaking: Bool {
        phase == .starting(side) || phase == .listening(side) || phase == .finishing(side)
    }
    /// A tap by this side starts a turn (idle) or ends it.
    private var endsTurn: Bool { phase == .starting(side) || phase == .listening(side) }

    var body: some View {
        VStack(spacing: 8) {
            if let picker { picker }
            history
            HStack(spacing: 12) {
                Button(action: tap) {
                    Text(endsTurn ? texts.stop : texts.speak).font(.title3).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(endsTurn ? .red : .accentColor)
                .disabled(phase != .idle && !endsTurn)
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("关闭")
                }
            }
            .controlSize(.large)
            .padding(.horizontal)
        }
        // Keeps the scroll view off the screen edge, where it would reach into the safe area
        // (which the rotated half does not turn with); the clip holds each half to its frame.
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var history: some View {
        ScrollView {
            // Not lazy: the height then changes only when the content does.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(utterances) { row($0) }
                if isSpeaking { speaking }
                if let notice { noticeText(notice) }
                if saveFailed {
                    Text("这条对话没有保存").font(.footnote).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            scrollToBottom()
        }
        .onChange(of: utterances.count) { scrollToBottom() }
    }

    @ViewBuilder private func row(_ entry: ConversationUtterance) -> some View {
        if entry.speaker == side {
            Text(entry.original).foregroundStyle(.secondary)
        } else if let translation = entry.translation {
            Text(translation).font(.title2)
        } else {
            Text(texts.translationFailed).font(.title3).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var speaking: some View {
        if !liveText.isEmpty {
            Text(liveText).foregroundStyle(.secondary)
        }
        Label(status, systemImage: phase == .listening(side) ? "mic.fill" : "ellipsis")
            .font(.footnote)
            .foregroundStyle(.tint)
    }

    private var status: String {
        switch phase {
        case .starting: texts.starting
        case .listening: texts.listening
        case .finishing: texts.finishing
        case .idle: ""
        }
    }

    @ViewBuilder private func noticeText(_ notice: ConversationShownNotice) -> some View {
        switch notice {
        case .notHeard:
            Text(texts.notHeard).foregroundStyle(.orange)
        case .failed:
            Text(texts.failed).font(.footnote).foregroundStyle(.red)
        case .reason(let reason):
            Text(reason).font(.footnote).foregroundStyle(.red)
        }
    }

    private func scrollToBottom() {
        withAnimation { position.scrollTo(edge: .bottom) }
    }
}
