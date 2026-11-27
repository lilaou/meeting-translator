import MeetingCore
import SwiftUI

/// Shown until the four language packs are there: what is missing, and "下载" / "取消" / "重试".
/// The close button works in every step, also while an install never returns.
struct ConversationPacksView: View {
    let packs: ConversationPacks
    let close: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("面对面翻译（中文 ↔ 韩语）").font(.headline)
            Spacer()
            step
            Spacer()
            Button("关闭", action: close).buttonStyle(.bordered)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var step: some View {
        switch packs.step {
        case .checking:
            ProgressView()
            Text("正在检查语言包…")
        case .missing(let missing):
            Text("还缺少以下语言包：")
            ForEach(missing, id: \.self) { Text(Self.name(of: $0)).foregroundStyle(.secondary) }
            Button("下载") { Task { await packs.download() } }
                .buttonStyle(.borderedProminent)
                .disabled(packs.isBusy)
        case .installing(let pack):
            progress("正在安装\(Self.name(of: pack))…")
        case .awaitingTranslationDownload(let side):
            progress("正在下载\(Self.name(of: .translation(from: side)))…")
        case .ready:
            // The page shows the conversation instead.
            EmptyView()
        case .failed(let message):
            Text(message)
            Button("重试") { Task { await packs.refresh() } }
                .buttonStyle(.borderedProminent)
                .disabled(packs.isBusy)
        }
    }

    @ViewBuilder private func progress(_ text: String) -> some View {
        ProgressView()
        Text(text)
        Button("取消") { packs.cancel() }
    }

    private static func name(of pack: ConversationPack) -> String {
        switch pack {
        case .speech(.chinese): "中文识别包"
        case .speech(.korean): "韩语识别包"
        case .translation(.chinese): "中文 → 韩语翻译包"
        case .translation(.korean): "韩语 → 中文翻译包"
        }
    }
}

/// A fake for the preview: nothing is installed.
private struct NothingInstalled: ConversationPackChecking {
    func conversationSpeechState(for locale: Locale) async -> PackState { .notInstalled }
    func translationState(from: Locale.Language, to: Locale.Language) async -> PackState {
        .notInstalled
    }
    func installSpeechPack(for locale: Locale) async throws {}
}

#Preview("missing packs") {
    @Previewable @State var packs = ConversationPacks(checking: NothingInstalled())
    ConversationPacksView(packs: packs, close: {})
        .task { await packs.refresh() }
}
