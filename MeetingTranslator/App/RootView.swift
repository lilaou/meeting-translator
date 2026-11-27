import MeetingCore
import SwiftUI

/// Root: the onboarding (with the language choice) until both packs of the chosen language are
/// ready and the user taps "开始", then the caption page. Starting only enters the page; no
/// meeting starts here. The caption page can send the user back here, to change the language,
/// or after a failure to check the packs (e.g. when the system removed one).
struct RootView: View {
    let selection: LanguageSelection
    @State private var started = false

    var body: some View {
        Group {
            if started, selection.onboarding.step == .ready {
                LiveCaptionView(language: selection.language, onShowOnboarding: { started = false })
            } else {
                OnboardingPage(selection: selection) { started = true }
            }
        }
        // A new "开始" tap is needed whenever the step has left `.ready` in between.
        .onChange(of: selection.onboarding.step) { _, step in
            if step != .ready { started = false }
        }
    }
}

struct StartupErrorView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 12) {
            Text("无法打开会议记录库")
                .font(.headline)
            Text("请重启应用；若仍失败，请检查设备存储空间。")
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
