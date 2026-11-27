import MeetingCore
import SwiftUI

/// Root: shows the page of `route`. At launch the preflight of the chosen language decides
/// between the caption page and the onboarding (with the language choice). From then on only
/// the user moves: "开始" on the onboarding (offered when it is ready), "更换语言" or "检查语言包"
/// on the caption page. The caption page does not depend on the onboarding's step, which is
/// untouched when launch led straight to it. Showing a page starts no meeting.
struct RootView: View {
    let route: AppRoute
    let selection: LanguageSelection

    var body: some View {
        switch route.page {
        case .launching:
            ProgressView()
                .task { await route.launch(locale: selection.language.locale) }
        case .onboarding:
            OnboardingPage(selection: selection) { route.showCaptions() }
        case .captions:
            LiveCaptionView(language: selection.language,
                            onShowOnboarding: { route.showOnboarding() })
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
