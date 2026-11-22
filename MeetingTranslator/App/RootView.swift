import MeetingCore
import SwiftUI

/// Placeholder root: 11c and 11d replace the two pages.
struct RootView: View {
    let onboarding: OnboardingModel

    var body: some View {
        switch onboarding.step {
        case .ready:
            Text("字幕页占位")
        default:
            Text("引导页占位")
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
