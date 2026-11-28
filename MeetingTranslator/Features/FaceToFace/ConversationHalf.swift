import MeetingCore
import SwiftUI

/// The two halves: the Korean one on top, turned to face the other person, the Chinese one
/// below. Plain values in, so previews use the same rendering path as production.
struct ConversationBoard: View {
    let phase: ConversationSession.Phase
    let liveText: String
    let utterances: [ConversationUtterance]
    let notice: ConversationSession.Notice?
    /// The latest save failed (`ConversationSession.saveFailed`).
    let saveFailed: Bool
    let lastSpeaker: ConversationSide
    let tap: (ConversationSide) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Rotation turns drawing, touches and scrolling together (to be seen on a device).
            half(.korean, close: nil).rotationEffect(.degrees(180))
            Divider()
            half(.chinese, close: close)
        }
    }

    private func half(_ side: ConversationSide, close: (() -> Void)?) -> some View {
        ConversationHalf(
            side: side, phase: phase, liveText: liveText, utterances: utterances,
            notice: notice?.shown(on: side, speaker: lastSpeaker),
            // Only the app's user, on the Chinese side, keeps the records.
            saveFailed: side == .chinese && saveFailed, tap: { tap(side) }, close: close)
    }
}

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
    @State private var position = ScrollPosition(edge: .bottom)

    private var texts: HalfTexts { HalfTexts(side) }
    private var isSpeaking: Bool {
        phase == .starting(side) || phase == .listening(side) || phase == .finishing(side)
    }
    /// A tap by this side starts a turn (idle) or ends it.
    private var endsTurn: Bool { phase == .starting(side) || phase == .listening(side) }

    var body: some View {
        VStack(spacing: 8) {
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

/// The fixed texts of one half, in its side's language.
private struct HalfTexts {
    let speak, stop, starting, listening, finishing, notHeard, translationFailed, failed: String

    init(_ side: ConversationSide) {
        switch side {
        case .chinese:
            (speak, stop) = ("我说中文", "结束")
            (starting, listening, finishing) = ("正在准备…", "在听…", "正在翻译…")
            (notHeard, translationFailed, failed) = ("没听清", "翻译失败", "出错了")
        case .korean:
            (speak, stop) = ("말하기", "멈추기")
            (starting, listening, finishing) = ("준비 중…", "듣는 중…", "번역 중…")
            (notHeard, translationFailed, failed) = ("잘 안 들렸어요", "번역 실패", "오류가 발생했어요")
        }
    }
}

extension ConversationBoard {
    @MainActor fileprivate static func sample(_ phase: ConversationSession.Phase,
                                              liveText: String = "") -> Self {
        Self(phase: phase, liveText: liveText,
             utterances: [
                ConversationUtterance(id: 0, speaker: .chinese, original: "你好，很高兴认识你。",
                                      translation: "안녕하세요, 만나서 반갑습니다."),
                ConversationUtterance(id: 1, speaker: .korean, original: "저도 반갑습니다.",
                                      translation: "我也很高兴。"),
                ConversationUtterance(id: 2, speaker: .korean, original: "점심 드셨어요?",
                                      translation: nil),
             ],
             notice: nil, saveFailed: false, lastSpeaker: .chinese, tap: { _ in }, close: {})
    }
}

#Preview("both halves") { ConversationBoard.sample(.idle) }
#Preview("listening") { ConversationBoard.sample(.listening(.chinese), liveText: "我们明天") }
#Preview("not heard") {
    ConversationBoard(phase: .idle, liveText: "", utterances: [], notice: .notHeard,
                      saveFailed: false, lastSpeaker: .korean, tap: { _ in }, close: {})
}
#Preview("Korean turn failed") {
    ConversationBoard(phase: .idle, liveText: "", utterances: [], notice: .failed("无法开始录音"),
                      saveFailed: false, lastSpeaker: .korean, tap: { _ in }, close: {})
}
#Preview("turn not saved") {
    ConversationBoard(
        phase: .idle, liveText: "",
        utterances: [ConversationUtterance(id: 0, speaker: .chinese, original: "你好。",
                                           translation: "안녕하세요.")],
        notice: nil, saveFailed: true, lastSpeaker: .chinese, tap: { _ in }, close: {})
}
