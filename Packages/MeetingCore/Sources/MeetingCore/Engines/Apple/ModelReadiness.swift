// SpeechTranscriber / AssetInventory and TranslationSession exist from the iOS 26 /
// macOS 26 SDKs on, which ship with Swift 6.2; older toolchains (and their SDKs) compile the
// package without this file.
#if compiler(>=6.2)
import Foundation
import Speech

/// `ReadinessChecking` on the Apple speech and translation packs. The preflight and the
/// self-test logic live in `ReadinessLogic`; this type only wires in the Apple APIs.
///
/// - Speech pack state comes from `SpeechTranscriber`'s installed and supported locales,
///   the same lists `AppleSpeechEngine` uses.
/// - Translation pack state is always that of the Apple pack into Simplified Chinese
///   (`AppleTranslator`), whatever translator is injected: `translationState` and
///   `preflight` ignore `translator`, which only `selfTest` uses. Harmless while Apple's is
///   the only translator; revisit in Task 11 / Phase 2 if a non-Apple translator arrives.
/// - `installSpeechPack` only installs the speech pack; translation packs are downloaded by
///   the app's onboarding (`.translationTask`).
/// - `selfTest` recognizes synthesized speech ("The meeting will start at nine tomorrow
///   morning.") with `engine` and translates "The meeting will start at nine." with
///   `translator`.
///
/// Unverified without a device: the real self-test (synthesis, recognition and translation
/// offline), whether an installed but unreserved locale can be transcribed, and whether the
/// pack-state queries stay fast and offline.
@available(iOS 26.0, macOS 26.0, *)
public struct ModelReadiness: ReadinessChecking {
    private let logic: ReadinessLogic

    public init(engine: any ASREngine, translator: any Translator) {
        self.init(engine: engine, translator: translator, audio: SynthesizedSpeech())
    }

    init(engine: any ASREngine, translator: any Translator, audio: any SelfTestAudioProvider) {
        logic = ReadinessLogic(engine: engine, translator: translator, packs: ApplePackStates(),
                               audio: audio)
    }

    public func speechState(for locale: Locale) async -> PackState {
        await ApplePackStates().speechState(for: locale)
    }

    public func translationState(from source: Locale.Language) async -> PackState {
        await ApplePackStates().translationState(from: source)
    }

    /// Reserves the locale for this app (if not yet) and downloads and installs its speech
    /// model (if not yet). Throws `ModelReadinessError`.
    public func installSpeechPack(for locale: Locale) async throws {
        guard let match = installedLocale(matching: locale, in: await SpeechTranscriber.supportedLocales)
        else { throw ModelReadinessError.speechUnsupported(locale.identifier(.bcp47)) }
        do {
            let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
            if !reserved.contains(match.identifier(.bcp47)) {
                _ = try await AssetInventory.reserve(locale: match)
            }
            let transcriber = AppleSpeechEngine.makeTranscriber(locale: match)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw ModelReadinessError.speechInstallFailed(error.localizedDescription)
        }
    }

    /// Throws `ReadinessFailure.selfTestFailed` with a readable reason when the self-test does
    /// not pass, or `CancellationError` unchanged when it was cancelled (treat that as
    /// "cancelled", not as a failure).
    public func selfTest(locale: Locale) async throws {
        try await logic.selfTest(locale: locale)
    }

    /// Fast and offline: reads the two pack states only; throws only `ReadinessFailure`.
    public func preflight(locale: Locale) async throws {
        try await logic.preflight(locale: locale)
    }
}

/// Pack states from the Apple APIs.
@available(iOS 26.0, macOS 26.0, *)
struct ApplePackStates: PackStateProviding {
    func speechState(for locale: Locale) async -> PackState {
        if installedLocale(matching: locale, in: await SpeechTranscriber.installedLocales) != nil {
            return .installed
        }
        let supported = installedLocale(matching: locale, in: await SpeechTranscriber.supportedLocales)
        return supported == nil ? .unsupported : .notInstalled
    }

    func translationState(from source: Locale.Language) async -> PackState {
        await AppleTranslator.packState(from: source)
    }
}
#endif
