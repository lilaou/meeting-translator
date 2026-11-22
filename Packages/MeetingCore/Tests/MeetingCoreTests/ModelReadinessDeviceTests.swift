// Needs the iOS 26 / macOS 26 SDK (Swift 6.2+), like AppleTranslator and ModelReadiness.
#if compiler(>=6.2)
import Foundation
import Testing
@testable import MeetingCore

private let deviceTestsEnabled = ProcessInfo.processInfo.environment["RUN_DEVICE_TESTS"] != nil
private let english = Locale(identifier: "en-US")
/// A private-use language with an unknown region: never supported, never installed.
private let impossible = Locale(identifier: "qaa-ZZ")

// MARK: - Device only (need the en-US speech pack and the en → zh-Hans translation pack)

@Test(.enabled(if: deviceTestsEnabled, "missing: RUN_DEVICE_TESTS is not set"))
func selfTestPassesWhenThePacksAreInstalled() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else {
        Issue.record("ModelReadiness needs iOS 26 / macOS 26")
        return
    }
    let readiness = ModelReadiness(engine: AppleSpeechEngine(), translator: AppleTranslator())
    try await readiness.preflight(locale: english)
    try await readiness.selfTest(locale: english)
}

@Test(.enabled(if: deviceTestsEnabled, "missing: RUN_DEVICE_TESTS is not set"))
func appleTranslatorTranslatesABatchIntoChinese() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else {
        Issue.record("AppleTranslator needs iOS 26 / macOS 26")
        return
    }
    let results = try await AppleTranslator().translateBatch(["Good morning.", "Thank you."],
                                                             from: english.language, context: [])
    #expect(results.count == 2)
    for result in results { #expect(ReadinessLogic.containsHan(result), "no Han character in \(result)") }
}

// MARK: - Runner smoke tests (no pack is assumed to be installed)

/// Smoke test only: both types conform and the state queries return, also without packs.
@Test func smokeReadinessAndTranslatorReportPackStates() async {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let translator: any Translator = AppleTranslator()
    let readiness: any ReadinessChecking = ModelReadiness(engine: AppleSpeechEngine(),
                                                          translator: translator)
    let speech = await readiness.speechState(for: english)
    let translation = await readiness.translationState(from: english.language)
    let canTranslate = await translator.canTranslate(from: english.language)
    print("ModelReadiness en-US speech: \(speech), en → zh-Hans translation: \(translation), "
          + "canTranslate: \(canTranslate)")
    #expect(canTranslate == (translation == .installed))
}

/// A locale that can never be installed: unsupported, preflight fails on the speech pack,
/// installing fails at once, and the translator throws instead of waiting.
@Test func readinessAndTranslatorRejectAnImpossibleLocale() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let translator = AppleTranslator()
    let readiness = ModelReadiness(engine: AppleSpeechEngine(), translator: translator)

    #expect(await readiness.speechState(for: impossible) == .unsupported)
    #expect(await readiness.translationState(from: impossible.language) != .installed)
    #expect(await !translator.canTranslate(from: impossible.language))
    await #expect(throws: ReadinessFailure.speechPackMissing) {
        try await readiness.preflight(locale: impossible)
    }
    await #expect(throws: ModelReadinessError.speechUnsupported("qaa-ZZ")) {
        try await readiness.installSpeechPack(for: impossible)
    }
    await #expect(throws: AppleTranslatorError.self) {
        _ = try await translator.translate("Hello.", from: impossible.language, context: [])
    }
    #expect(try await translator.translateBatch([], from: impossible.language, context: []) == [])
}
#endif
