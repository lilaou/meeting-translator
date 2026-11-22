import Foundation
import Testing
@testable import MeetingCore

private let english = Locale(identifier: "en-US")

@MainActor
private func model(_ readiness: ScriptedReadiness) -> OnboardingModel {
    OnboardingModel(readiness: readiness, locale: english)
}

// MARK: - cancel

@MainActor @Test func cancelDuringTheInstallReturnsToNeedsSetupWithoutALeak() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                      blocking: [.install])
    let onboarding = model(readiness)
    await onboarding.refresh()
    let setup = Task { await onboarding.startSetup() }
    await readiness.entered(.install)
    #expect(onboarding.step == .installingSpeech)

    onboarding.cancel()
    #expect(onboarding.step == .needsSetup(speech: .notInstalled, translation: .notInstalled))
    onboarding.cancel() // a second cancel is safe
    await setup.value   // returns only after the install task has ended
    #expect(onboarding.step == .needsSetup(speech: .notInstalled, translation: .notInstalled))
    #expect(!onboarding.isBusy)
    #expect(readiness.inFlight == 0)
    #expect(readiness.count(.selfTest) == 0)

    // Setup can start again (the install gate is open now).
    await onboarding.startSetup()
    #expect(onboarding.step == .awaitingTranslationDownload)
    #expect(readiness.count(.install) == 2)
}

@MainActor @Test func cancelDuringTheSelfTestIsNotAFailure() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed, blocking: [.selfTest])
    let onboarding = model(readiness)
    let refresh = Task { await onboarding.refresh() }
    await readiness.entered(.selfTest)
    #expect(onboarding.step == .selfTesting)

    onboarding.cancel()
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .installed))
    await refresh.value
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .installed))
    #expect(!onboarding.isBusy)
    #expect(readiness.inFlight == 0)

    // Starting again re-runs the self-test (both packs are installed, so no install).
    await onboarding.startSetup()
    #expect(onboarding.step == .ready)
    #expect(readiness.count(.install) == 0)
    #expect(readiness.count(.selfTest) == 2)
}

@MainActor @Test func cancelWhileWaitingForTheDownloadIgnoresALateReport() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let onboarding = model(readiness)
    await onboarding.refresh()
    await onboarding.startSetup()
    #expect(onboarding.step == .awaitingTranslationDownload)

    onboarding.cancel()
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .notInstalled))
    readiness.setTranslation(.installed)
    await onboarding.translationDownloadFinished(error: nil)
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .notInstalled))
    #expect(readiness.count(.selfTest) == 0)
}

@MainActor @Test func cancelBeforeAnyStateIsKnownGoesBackToChecking() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed,
                                      blocking: [.speechState])
    let onboarding = model(readiness)
    let refresh = Task { await onboarding.refresh() }
    await readiness.entered(.speechState)
    onboarding.cancel()
    await refresh.value
    #expect(onboarding.step == .checking)
    #expect(!onboarding.isBusy)
    #expect(readiness.count(.selfTest) == 0)
}

@MainActor @Test func setupAfterACancelWaitsForAnInstallThatIgnoresCancellation() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                      blocking: [.install], honorsCancellation: false)
    let onboarding = model(readiness)
    await onboarding.refresh()
    let first = Task { await onboarding.startSetup() }
    await readiness.entered(.install)
    onboarding.cancel()
    #expect(onboarding.isBusy) // the stuck install is still draining
    let second = Task { await onboarding.startSetup() }
    let needsSetup = OnboardingModel.Step.needsSetup(speech: .notInstalled, translation: .notInstalled)
    // Ends when the second call waits, or (wrongly) as soon as it starts a setup of its own.
    await waitUntil { onboarding.callsWaitingForCancelledJob == 1 || onboarding.step != needsSetup }
    #expect(onboarding.callsWaitingForCancelledJob == 1)
    #expect(onboarding.step == needsSetup) // the second setup has not started
    #expect(readiness.count(.install) == 1)
    readiness.release(.install)
    await first.value
    await second.value
    #expect(readiness.maxInFlight == 1) // never two setups at once
    #expect(readiness.count(.install) == 2)
    #expect(onboarding.step == .awaitingTranslationDownload)
    #expect(!onboarding.isBusy)
    #expect(onboarding.callsWaitingForCancelledJob == 0)
}

// MARK: - calls in the wrong state

@MainActor @Test func callsWhileRunningAreIgnored() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed, blocking: [.selfTest])
    let onboarding = model(readiness)
    let refresh = Task { await onboarding.refresh() }
    await readiness.entered(.selfTest)

    await onboarding.refresh()
    await onboarding.startSetup()
    await onboarding.retry()
    await onboarding.translationDownloadFinished(error: FakeError.translation)
    #expect(onboarding.step == .selfTesting)
    #expect(readiness.count(.speechState) == 1)
    #expect(readiness.count(.selfTest) == 1)

    readiness.release(.selfTest)
    await refresh.value
    #expect(onboarding.step == .ready)
    #expect(readiness.maxInFlight == 1)
}

@MainActor @Test func callsInTheWrongIdleStateAreNoOps() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled)
    let onboarding = model(readiness)
    onboarding.cancel()
    await onboarding.startSetup()
    await onboarding.retry()
    await onboarding.translationDownloadFinished(error: nil)
    #expect(onboarding.step == .checking)
    #expect(readiness.calls.isEmpty)

    await onboarding.refresh()
    let needsSetup = OnboardingModel.Step.needsSetup(speech: .notInstalled, translation: .notInstalled)
    #expect(onboarding.step == needsSetup)
    await onboarding.retry()
    await onboarding.translationDownloadFinished(error: FakeError.translation)
    onboarding.cancel()
    #expect(onboarding.step == needsSetup)

    await onboarding.startSetup()
    #expect(onboarding.step == .awaitingTranslationDownload)
    let queries = readiness.calls.count
    await onboarding.refresh() // the view's download is in flight: ignored
    await onboarding.startSetup()
    await onboarding.retry()
    #expect(onboarding.step == .awaitingTranslationDownload)
    #expect(readiness.calls.count == queries)
}

@MainActor @Test func readyAndFailedIgnoreSetupAndCancel() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed,
                                      selfTestErrors: [FakeError.asr])
    let onboarding = model(readiness)
    await onboarding.refresh()
    let failed = onboarding.step
    onboarding.cancel()
    await onboarding.startSetup()
    #expect(onboarding.step == failed)

    await onboarding.retry()
    #expect(onboarding.step == .ready)
    onboarding.cancel()
    await onboarding.startSetup()
    await onboarding.retry()
    #expect(onboarding.step == .ready)
    #expect(readiness.count(.selfTest) == 2)
    #expect(readiness.count(.install) == 0)
}
