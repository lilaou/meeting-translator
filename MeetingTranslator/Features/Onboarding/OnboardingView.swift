import MeetingCore
import SwiftUI

/// The onboarding screen: connects `OnboardingModel` to `OnboardingContent`, runs `refresh()`
/// when it appears (the `.task` is cancelled with the view, which cancels the model's job) and
/// `cancel()` when it disappears, and downloads the translation pack.
struct OnboardingView: View {
    let onboarding: OnboardingModel
    let direction: String
    let onStart: () -> Void

    init(onboarding: OnboardingModel,
         direction: String = CaptionStrings.direction(from: AppAssembly.sourceLocale),
         onStart: @escaping () -> Void) {
        self.onboarding = onboarding
        self.direction = direction
        self.onStart = onStart
    }

    var body: some View {
        OnboardingContent(
            step: onboarding.step, isBusy: onboarding.isBusy, direction: direction,
            download: { Task { await onboarding.startSetup() } },
            retry: { Task { await onboarding.retry() } },
            cancel: { onboarding.cancel() },
            start: onStart)
            .translationDownload(for: onboarding)
            .task { await onboarding.refresh() }
            .onDisappear { onboarding.cancel() }
    }
}

/// Renders one `Step`; a plain value in, so previews can show every step with fake data.
struct OnboardingContent: View {
    let step: OnboardingModel.Step
    let isBusy: Bool
    let direction: String
    let download: () -> Void
    let retry: () -> Void
    let cancel: () -> Void
    let start: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .checking:
                progress("正在检查语言包…")
            case .needsSetup(let speech, let translation):
                needsSetup(speech: speech, translation: translation)
            case .installingSpeech:
                progress("正在安装识别包…", cancellable: true)
            case .awaitingTranslationDownload:
                progress("正在下载翻译包…", cancellable: true)
            case .selfTesting:
                progress("正在自检…", cancellable: true)
            case .ready:
                Text("已就绪，可离线使用").font(.headline)
                Button("开始", action: start).buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message).multilineTextAlignment(.center)
                Button("重试", action: retry).disabled(isBusy).buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func progress(_ text: String, cancellable: Bool = false) -> some View {
        ProgressView()
        Text(text)
        if cancellable { Button("取消", action: cancel) }
    }

    @ViewBuilder
    private func needsSetup(speech: PackState, translation: PackState) -> some View {
        Text(direction).font(.title2)
        VStack(alignment: .leading, spacing: 8) {
            row("识别包", speech)
            row("翻译包", translation)
        }
        if speech == .installed, translation == .installed {
            Text("还需要完成一次自检")
        }
        Button("下载", action: download).disabled(isBusy).buttonStyle(.borderedProminent)
    }

    private func row(_ title: String, _ state: PackState) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Self.text(for: state)).foregroundStyle(.secondary)
        }
    }

    private static func text(for state: PackState) -> String {
        switch state {
        case .notInstalled: "未安装"
        case .installed: "已安装"
        case .unsupported: "不支持"
        }
    }
}

extension OnboardingContent {
    fileprivate static func sample(_ step: OnboardingModel.Step, busy: Bool = false) -> Self {
        Self(step: step, isBusy: busy, direction: "英语 → 中文",
             download: {}, retry: {}, cancel: {}, start: {})
    }
}

#Preview("checking") { OnboardingContent.sample(.checking) }
#Preview("needsSetup") { OnboardingContent.sample(.needsSetup(speech: .notInstalled, translation: .notInstalled)) }
#Preview("needsSetup, self-test only") {
    OnboardingContent.sample(.needsSetup(speech: .installed, translation: .installed))
}
#Preview("needsSetup, busy") {
    OnboardingContent.sample(.needsSetup(speech: .installed, translation: .notInstalled), busy: true)
}
#Preview("installingSpeech") { OnboardingContent.sample(.installingSpeech) }
#Preview("awaitingTranslationDownload") { OnboardingContent.sample(.awaitingTranslationDownload) }
#Preview("selfTesting") { OnboardingContent.sample(.selfTesting) }
#Preview("ready") { OnboardingContent.sample(.ready) }
#Preview("failed") { OnboardingContent.sample(.failed("翻译离线包下载失败：网络不可用")) }
