// `ModelReadiness` exists from the iOS 26 / macOS 26 SDKs on (see ModelReadiness.swift).
#if compiler(>=6.2)
import Foundation
import Speech

/// The face-to-face language packs. `installSpeechPack(for:)` is `ModelReadiness`'s own (it
/// reserves and never releases); the speech state also requires the reservation (see
/// `reservedSpeechState`), and the translation state takes its target here.
@available(iOS 26.0, macOS 26.0, *)
extension ModelReadiness: ConversationPackChecking {
    public func conversationSpeechState(for locale: Locale) async -> PackState {
        reservedSpeechState(for: locale,
                            supported: await SpeechTranscriber.supportedLocales,
                            installed: await SpeechTranscriber.installedLocales,
                            reserved: await AssetInventory.reservedLocales)
    }

    public func translationState(from source: Locale.Language, to target: Locale.Language) async -> PackState {
        await AppleTranslator.packState(from: source, to: target)
    }
}
#endif
