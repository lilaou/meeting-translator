import MeetingCore
import SwiftUI

/// The two halves: the partner's on top, turned to face the other person, the Chinese one
/// below. Plain values in, so previews use the same rendering path as production.
struct ConversationBoard: View {
    /// Its `partner` is the language of the upper half.
    let picker: PartnerPicker
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
            half(picker.partner).rotationEffect(.degrees(180))
            Divider()
            half(.chinese)
        }
    }

    /// Only the app's user, on the Chinese side, chooses the language, closes the page and
    /// keeps the records.
    private func half(_ side: ConversationSide) -> some View {
        ConversationHalf(
            side: side, phase: phase, liveText: liveText, utterances: utterances,
            notice: notice?.shown(on: side, speaker: lastSpeaker),
            saveFailed: side == .chinese && saveFailed, tap: { tap(side) },
            close: side == .chinese ? close : nil, picker: side == .chinese ? picker : nil)
        // Without it, Japanese kanji may be drawn with Chinese glyph shapes.
        .typesettingLanguage(side.translationLanguage)
    }
}

@MainActor private func previewPicker(_ partner: ConversationSide = .korean) -> PartnerPicker {
    PartnerPicker(partner: partner, canChoose: true, choose: { _ in })
}

extension ConversationBoard {
    @MainActor fileprivate static func sample(_ phase: ConversationSession.Phase,
                                              liveText: String = "") -> Self {
        Self(picker: previewPicker(), phase: phase, liveText: liveText,
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
    ConversationBoard(picker: previewPicker(), phase: .idle, liveText: "", utterances: [],
                      notice: .notHeard, saveFailed: false, lastSpeaker: .korean,
                      tap: { _ in }, close: {})
}
#Preview("Korean turn failed") {
    ConversationBoard(picker: previewPicker(), phase: .idle, liveText: "", utterances: [],
                      notice: .failed("无法开始录音"), saveFailed: false, lastSpeaker: .korean,
                      tap: { _ in }, close: {})
}
#Preview("turn not saved") {
    ConversationBoard(
        picker: previewPicker(), phase: .idle, liveText: "",
        utterances: [ConversationUtterance(id: 0, speaker: .chinese, original: "你好。",
                                           translation: "안녕하세요.")],
        notice: nil, saveFailed: true, lastSpeaker: .chinese, tap: { _ in }, close: {})
}
#Preview("Japanese partner") {
    ConversationBoard(
        picker: previewPicker(.japanese), phase: .idle, liveText: "",
        utterances: [
            ConversationUtterance(id: 0, speaker: .chinese, original: "请问车站怎么走？",
                                  translation: "駅への行き方を教えてください。"),
            ConversationUtterance(id: 1, speaker: .japanese, original: "まっすぐ行ってください。",
                                  translation: "请直走。"),
        ],
        notice: nil, saveFailed: false, lastSpeaker: .japanese, tap: { _ in }, close: {})
}
