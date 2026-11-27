// `ModelReadiness` exists from the iOS 26 / macOS 26 SDKs on (see ModelReadiness.swift).
#if compiler(>=6.2)
import Foundation

/// The face-to-face language packs. `speechState(for:)` and `installSpeechPack(for:)` are
/// `ModelReadiness`'s own; only the translation state takes its target here.
@available(iOS 26.0, macOS 26.0, *)
extension ModelReadiness: ConversationPackChecking {
    public func translationState(from source: Locale.Language, to target: Locale.Language) async -> PackState {
        await AppleTranslator.packState(from: source, to: target)
    }
}
#endif
