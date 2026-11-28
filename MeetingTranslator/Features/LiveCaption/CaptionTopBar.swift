import MeetingCore
import SwiftUI

/// Direction, elapsed time, "离线" badge, (while translation is behind) "翻译滞后" and the
/// "面对面" and history buttons. The buttons and badges never shrink: a long direction is
/// truncated instead, and the history button is an icon (labelled "历史记录") to save room.
struct CaptionTopBar: View {
    let direction: String
    /// `coordinator.startedAt` while a meeting is running; nil means no running meeting, so no time
    /// is shown (obligation 14). The coordinator never clears `startedAt` after wrap-up, so the
    /// caller must pass nil once the meeting is over, or the clock would count up forever.
    let startedAt: Date?
    let isLagging: Bool
    /// False while a meeting is being prepared, running or wrapping up.
    let canLeave: Bool
    let faceToFace: () -> Void
    let history: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(direction).font(.headline).truncationMode(.middle)
            if let startedAt {
                // `TimelineView` supplies the ever-changing `now`; the coordinator publishes
                // only the start date, so nothing else would make the clock tick.
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(CaptionFormatting.elapsedText(since: startedAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Spacer()
            if isLagging { badge(CaptionStrings.lagging, tint: .orange) }
            badge(CaptionStrings.offline, tint: .green)
            Group {
                Button("面对面", action: faceToFace)
                Button(action: history) { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("历史记录")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(!canLeave)
        }
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.2), in: Capsule())
            .fixedSize()
    }
}

#Preview("running, lagging") {
    CaptionTopBar(direction: "英语 → 中文", startedAt: .now.addingTimeInterval(-754), isLagging: true,
                  canLeave: false, faceToFace: {}, history: {})
}
#Preview("no meeting") {
    CaptionTopBar(direction: "英语 → 中文", startedAt: nil, isLagging: false,
                  canLeave: true, faceToFace: {}, history: {})
}
#Preview("running, lagging, long direction, large type") {
    CaptionTopBar(direction: "韩语 → 中文（简体）", startedAt: .now.addingTimeInterval(-3_754),
                  isLagging: true, canLeave: false, faceToFace: {}, history: {})
        .dynamicTypeSize(.xxxLarge)
}
