import MeetingCore
import SwiftUI

/// The caption page: connects `SessionCoordinator` to `LiveCaptionContent`.
///
/// Start and finish run in an unstructured `Task` created by the button action, NOT in `.task`
/// or `.onChange`. SwiftUI cancels those when the view disappears or its inputs change, and
/// `start` awaits `readiness.preflight` and the engine/audio connection inside the calling
/// task, so a cancellable caller could abort preparation or the wrap-up; a meeting must not
/// end because the page re-rendered or the user left it. A button's `Task` is never cancelled
/// by SwiftUI. It captures only the coordinator (a `@MainActor` class read from the
/// environment), so nothing non-`Sendable` crosses an isolation boundary.
struct LiveCaptionView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    /// Back to the onboarding page (offered after a failure; see `RootView`).
    let onCheckPacks: () -> Void

    private var runningSince: Date? {
        switch coordinator.state {
        case .listening, .finishing: coordinator.startedAt
        case .idle, .preparing, .failed: nil
        }
    }

    var body: some View {
        LiveCaptionContent(
            state: coordinator.state, isLagging: coordinator.isTranslationLagging,
            // Shown only while a meeting runs; `startedAt` is not cleared after wrap-up.
            startedAt: runningSince,
            direction: CaptionStrings.direction(from: AppAssembly.sourceLocale),
            start: { [coordinator] in
                Task { await coordinator.start(locale: AppAssembly.sourceLocale) }
            },
            finish: { [coordinator] in Task { await coordinator.finish() } },
            checkPacks: onCheckPacks
        ) {
            // The list follows `meetingID`: a new meeting gets a new identity, hence a fresh
            // `Query` and a fresh follow state. Without a meeting (before the first start,
            // or a failed start) there is nothing to query.
            if let meetingID = coordinator.meetingID {
                // Only `VolatileLine` reads `volatileText`, so partial-recognition updates do
                // not re-render this view, rebuild the `Query` or re-map the rows.
                CaptionListView(meetingID: meetingID) { VolatileLine() }
                    .id(meetingID)
            } else {
                Color.clear
            }
        }
        .keepScreenAwake(coordinator.state.keepsScreenAwake)
    }
}

/// Renders one coordinator state around a list; plain values in, so previews cover every state
/// through the same rendering path as production.
struct LiveCaptionContent<ListContent: View>: View {
    let state: SessionCoordinator.State
    let isLagging: Bool
    let startedAt: Date?
    let direction: String
    let start: () -> Void
    let finish: () -> Void
    let checkPacks: () -> Void
    @ViewBuilder let list: ListContent

    var body: some View {
        VStack(spacing: 0) {
            CaptionTopBar(direction: direction, startedAt: startedAt, isLagging: isLagging)
            list
            Divider()
            statusArea
            buttons.padding()
        }
    }

    /// Progress or the failure reason, between the list and the buttons, so the stored
    /// captions stay visible in every state.
    @ViewBuilder private var statusArea: some View {
        switch state {
        case .preparing: progress("正在准备…")
        // Wrap-up may take about 40 seconds (audio, recognition and translation bounds).
        case .finishing: progress("正在整理收尾…")
        case .failed(let message):
            // The message may join several problems with "；": one per line.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.lines(of: message).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])
        case .idle, .listening: EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch state {
        case .idle:
            primary(CaptionStrings.start, action: start)
        case .preparing, .finishing:
            primary(state == .preparing ? CaptionStrings.start : CaptionStrings.finish, action: {})
                .disabled(true)
        case .listening:
            primary(CaptionStrings.finish, action: finish)
        case .failed:
            HStack {
                Button("检查语言包", action: checkPacks).buttonStyle(.bordered)
                primary("重新开始", action: start)
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    private func progress(_ text: String) -> some View {
        HStack { ProgressView(); Text(text).foregroundStyle(.secondary) }.padding(.top)
    }

    static func lines(of message: String) -> [String] {
        message.split(separator: "；").map(String.init).filter { !$0.isEmpty }
    }
}

extension LiveCaptionContent where ListContent == CaptionListContent<Text> {
    @MainActor fileprivate static func sample(
        _ state: SessionCoordinator.State, lagging: Bool = false, started: Bool = true,
        rows: [CaptionRow] = (1...3).map { .sample($0) }, volatile: String = ""
    ) -> Self {
        Self(state: state, isLagging: lagging,
             startedAt: started ? .now.addingTimeInterval(-125) : nil,
             direction: "英语 → 中文", start: {}, finish: {}, checkPacks: {}) {
            CaptionListContent(rows: rows) {
                Text(volatile).font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("idle, empty") { LiveCaptionContent.sample(.idle, started: false, rows: []) }
#Preview("preparing") { LiveCaptionContent.sample(.preparing, started: false, rows: []) }
#Preview("listening") { LiveCaptionContent.sample(.listening, volatile: "and then we") }
#Preview("listening, lagging") { LiveCaptionContent.sample(.listening, lagging: true) }
#Preview("finishing") { LiveCaptionContent.sample(.finishing) }
#Preview("failed, two reasons") {
    LiveCaptionContent.sample(.failed("识别在会议结束时未能及时完成；有 2 句尚未完成翻译（原文已保存）"))
}
