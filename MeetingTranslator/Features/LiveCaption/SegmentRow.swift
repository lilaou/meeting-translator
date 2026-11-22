import MeetingCore
import SwiftUI

/// One caption row as a plain value: the stored segment's id (stable identity for the list) and
/// what to show. Rows are copied out of `@Model` objects on the main actor, so the rendering
/// path below never touches SwiftData and previews can feed it fake data.
struct CaptionRow: Identifiable, Equatable {
    let id: UUID
    let display: SegmentDisplay
}

/// Source text small on top, translation large below; the row state comes from `SegmentDisplay`.
struct SegmentRow: View {
    let display: SegmentDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if display.kind != .interruption {
                Text(display.sourceText).font(.footnote).foregroundStyle(.secondary)
            }
            Text(display.translationText)
                .font(display.kind == .interruption ? .callout : .title3)
                .foregroundStyle(translationStyle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Pending, failed and interruption rows are dimmed or tinted so they read as "not a
    /// translation": the user must not mistake "…" or "（翻译失败）" for the speaker's words.
    private var translationStyle: HierarchicalShapeStyle {
        switch display.kind {
        case .translated: .primary
        case .pending, .failed, .interruption: .secondary
        }
    }
}

#Preview("rows") {
    VStack(alignment: .leading, spacing: 16) {
        SegmentRow(display: .init(status: .translated, sourceText: "Let's begin.", translatedText: "我们开始吧。"))
        SegmentRow(display: .init(status: .pendingTranslation, sourceText: "Next item.", translatedText: nil))
        SegmentRow(display: .init(status: .translationFailed, sourceText: "Budget review.", translatedText: nil))
        SegmentRow(display: .init(status: .interruptionMarker, sourceText: "", translatedText: nil))
    }
    .padding()
}
