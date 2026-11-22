import Foundation
import Observation
import Synchronization
import Testing
@testable import MeetingCore

// What the onboarding view relies on beyond `step` (final review of task 11a).

private let english = Locale(identifier: "en-US")

// MARK: - the language pair of the view's download (F-A)

@Test func theFixedTargetLanguageIsSimplifiedChinese() {
    #expect(TranslationTarget.language == Locale.Language(identifier: "zh-Hans"))
    #expect(TranslationTarget.language.languageCode == .chinese)
    #expect(TranslationTarget.language.script == .hanSimplified)
}

@MainActor @Test func theModelNamesThePairTheViewMustDownload() {
    let onboarding = OnboardingModel(readiness: ScriptedReadiness(speech: .installed, translation: .installed),
                                     locale: english)
    #expect(onboarding.translationSource == english.language)
    #expect(onboarding.translationSource == Locale.Language(identifier: "en-US"))
    #expect(onboarding.translationTarget == TranslationTarget.language)
}

/// The pair the model checks is the pair it names: the source it passes to
/// `translationState(from:)` is `translationSource`.
@MainActor @Test func theCheckedSourceIsTheNamedSource() async {
    let readiness = RecordingSourceReadiness()
    let onboarding = OnboardingModel(readiness: readiness, locale: english)
    await onboarding.refresh()
    #expect(readiness.sources == [onboarding.translationSource])
}

/// `ReadinessChecking` that records the source of every translation-state query.
private final class RecordingSourceReadiness: ReadinessChecking, Sendable {
    private let recorded = Mutex<[Locale.Language]>([])
    var sources: [Locale.Language] { recorded.withLock { $0 } }

    func speechState(for locale: Locale) async -> PackState { .installed }
    func translationState(from source: Locale.Language) async -> PackState {
        recorded.withLock { $0.append(source) }
        return .notInstalled
    }
    func installSpeechPack(for locale: Locale) async throws {}
    func selfTest(locale: Locale) async throws {}
    func preflight(locale: Locale) async throws {}
}

// MARK: - isBusy (F-E)

/// `isBusy` is true while a job runs and while a cancelled job is still draining, false
/// otherwise; and it is observable, so a disabled button comes back when a drain ends without
/// any change of `step`.
@MainActor @Test func isBusyCoversRunningAndDrainingJobsAndIsObservable() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                      blocking: [.install], honorsCancellation: false)
    let onboarding = OnboardingModel(readiness: readiness, locale: english)
    #expect(!onboarding.isBusy)                  // idle
    await onboarding.refresh()
    #expect(!onboarding.isBusy)                  // after a completed job
    let setup = Task { await onboarding.startSetup() }
    await readiness.entered(.install)
    #expect(onboarding.isBusy)                   // during a job

    onboarding.cancel()
    let needsSetup = OnboardingModel.Step.needsSetup(speech: .notInstalled, translation: .notInstalled)
    #expect(onboarding.step == needsSetup)
    #expect(onboarding.isBusy)                   // the cancelled install is still draining
    let changed = Mutex(false)
    withObservationTracking { _ = onboarding.isBusy } onChange: { changed.withLock { $0 = true } }
    readiness.release(.install)
    await setup.value
    #expect(!onboarding.isBusy)                  // the drain has ended
    #expect(onboarding.step == needsSetup)       // ... without any change of step
    #expect(changed.withLock { $0 })             // ... and observers were told
}
