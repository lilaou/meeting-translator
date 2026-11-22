import MeetingCore
import SwiftUI

/// Direction, elapsed time, "离线" badge and (while translation is behind) "翻译滞后".
struct CaptionTopBar: View {
    let direction: String
    /// `coordinator.startedAt`; nil means no meeting has started, so no time is shown (obligation 14).
    let startedAt: Date?
    let isLagging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(direction).font(.headline)
            if let startedAt {
                // `TimelineView` supplies the ever-changing `now`; the coordinator publishes
                // only the start date, so nothing else would make the clock tick.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CaptionFormatting.elapsedText(since: startedAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLagging { badge(CaptionStrings.lagging, tint: .orange) }
            badge(CaptionStrings.offline, tint: .green)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.2), in: Capsule())
    }
}

#Preview("running, lagging") {
    CaptionTopBar(direction: "英语 → 中文", startedAt: .now.addingTimeInterval(-754), isLagging: true)
}
#Preview("no meeting") {
    CaptionTopBar(direction: "英语 → 中文", startedAt: nil, isLagging: false)
}
