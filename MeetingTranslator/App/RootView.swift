import MeetingCore
import SwiftUI

/// Root: the onboarding until both packs are ready and the user taps "开始", then the caption
/// page (a placeholder until 11d). Starting only enters the page; no meeting starts here.
struct RootView: View {
    let onboarding: OnboardingModel
    @State private var started = false

    var body: some View {
        if started, onboarding.step == .ready {
            Text("字幕页占位")
        } else {
            OnboardingView(onboarding: onboarding) { started = true }
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
