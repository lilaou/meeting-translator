import Foundation
import Synchronization
import Testing
@testable import MeetingCore

// The one choice of source language and the onboarding model that belongs to it.

/// What a selection saved, and the meeting state it is told.
@MainActor private final class Host {
    var saved: [String] = []
    var meeting: SessionCoordinator.State = .idle

    func selection(_ readiness: any ReadinessChecking, stored: String? = nil) -> LanguageSelection {
        LanguageSelection(readiness: readiness, storedIdentifier: stored,
                          save: { self.saved.append($0) }, meetingState: { self.meeting })
    }
}

/// Records the locale or source language of every call that takes one.
private final class LocaleRecordingReadiness: ReadinessChecking, Sendable {
    private let log = Mutex<[String]>([])
    var asked: [String] { log.withLock { $0 } }
    private func record(_ value: String) { log.withLock { $0.append(value) } }

    func speechState(for locale: Locale) async -> PackState {
        record(locale.identifier)
        return .installed
    }
    func translationState(from source: Locale.Language) async -> PackState {
        record(source.languageCode?.identifier ?? "")
        return .installed
    }
    func installSpeechPack(for locale: Locale) async throws { record(locale.identifier) }
    func selfTest(locale: Locale) async throws { record(locale.identifier) }
    func preflight(locale: Locale) async throws {}
}

private func installed() -> ScriptedReadiness { ScriptedReadiness(speech: .installed, translation: .installed) }

@MainActor @Test func aSelectionStartsWithTheStoredLanguageOrEnglish() {
    let host = Host()
    for (stored, expected) in [(nil, "en-US"), ("ja-JP", "en-US"), ("ko-KR", "ko-KR")] {
        let selection = host.selection(installed(), stored: stored)
        #expect(selection.language.identifier == expected)
        #expect(selection.onboarding.translationSource == Locale.Language(identifier: expected))
    }
    #expect(host.saved.isEmpty)
}

@MainActor @Test func selectingAnotherLanguageSavesItAndMakesAFreshModelForIt() async {
    let readiness = LocaleRecordingReadiness()
    let host = Host()
    let selection = host.selection(readiness)
    await selection.onboarding.refresh()
    let english = selection.onboarding
    #expect(english.step == .ready)

    selection.select("ko-KR")
    #expect(selection.language.identifier == "ko-KR")
    #expect(host.saved == ["ko-KR"])
    #expect(selection.onboarding !== english)
    #expect(selection.onboarding.step == .checking)   // nothing runs until the view refreshes it
    #expect(selection.onboarding.translationSource == Locale.Language(identifier: "ko-KR"))

    await selection.onboarding.refresh()
    #expect(selection.onboarding.step == .ready)
    #expect(readiness.asked == ["en-US", "en", "en-US", "ko-KR", "ko", "ko-KR"])
}

@MainActor @Test func selectingTheSameOrAnUnlistedLanguageChangesNothing() {
    let host = Host()
    let selection = host.selection(installed())
    let model = selection.onboarding
    selection.select("en-US")
    selection.select("ja-JP")
    selection.select("")
    #expect(selection.onboarding === model)
    #expect(selection.language.identifier == "en-US")
    #expect(host.saved.isEmpty)
}

@MainActor private func expectRefused(_ selection: LanguageSelection, _ host: Host) {
    let model = selection.onboarding
    let step = model.step
    #expect(!selection.canChange)
    selection.select("ko-KR")
    #expect(selection.language.identifier == "en-US")
    #expect(selection.onboarding === model)
    #expect(model.step == step)   // a refused change does not cancel anything
    #expect(host.saved.isEmpty)
}

@MainActor @Test(arguments: [SessionCoordinator.State.preparing, .listening, .finishing])
func theLanguageCannotChangeDuringAMeeting(state: SessionCoordinator.State) {
    let host = Host()
    let selection = host.selection(installed())
    host.meeting = state
    expectRefused(selection, host)
}

@MainActor @Test(arguments: [SessionCoordinator.State.idle, .failed("x")])
func theLanguageCanChangeWithoutARunningMeeting(state: SessionCoordinator.State) {
    let host = Host()
    let selection = host.selection(installed())
    host.meeting = state
    #expect(selection.canChange)
}

@MainActor @Test(arguments: [ScriptedReadiness.Call.speechState, .install, .selfTest])
func theLanguageCannotChangeWhileAJobRunsOrDrains(blocked: ScriptedReadiness.Call) async {
    let speech: PackState = blocked == .install ? .notInstalled : .installed
    let readiness = ScriptedReadiness(speech: speech, translation: .installed,
                                      blocking: [blocked], honorsCancellation: false)
    let host = Host()
    let selection = host.selection(readiness)
    let model = selection.onboarding
    let job = Task {
        await model.refresh()
        await model.startSetup()
    }
    await readiness.entered(blocked)
    expectRefused(selection, host)

    model.cancel()                       // the cancelled job still drains
    expectRefused(selection, host)

    job.cancel()
    readiness.release(blocked)
    await job.value
    #expect(selection.canChange)
}

@MainActor @Test func theLanguageCannotChangeDuringTheTranslationDownloadAndItsReportStaysWithTheOldModel() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let host = Host()
    let selection = host.selection(readiness)
    let english = selection.onboarding
    await english.refresh()
    await english.startSetup()
    #expect(english.step == .awaitingTranslationDownload)
    expectRefused(selection, host)

    english.cancel()
    selection.select("ko-KR")
    let selfTests = readiness.count(.selfTest)
    // A late report of the old download reaches only the old model, which ignores it.
    readiness.setTranslation(.installed)
    await english.translationDownloadFinished(error: nil)
    #expect(selection.onboarding.step == .checking)
    #expect(!selection.onboarding.isBusy)
    #expect(readiness.count(.selfTest) == selfTests)
}
