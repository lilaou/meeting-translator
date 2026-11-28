import Foundation
import Synchronization
import Testing
@testable import MeetingCore

// Which page the app shows: the launch preflight decides once, the user afterwards.

private let korean = Locale(identifier: "ko-KR")

/// A readiness whose `preflight` records its call, optionally waits for `release`, then throws
/// `CancellationError` if its task was cancelled, else `error` if there is one.
private final class PreflightReadiness: ReadinessChecking, Sendable {
    let entered = Gate()
    let release = Gate()
    private let error: (any Error)?
    private let blocks: Bool
    private let log = Mutex<[String]>([])
    var calls: [String] { log.withLock { $0 } }

    init(error: (any Error)? = nil, blocks: Bool = false) {
        self.error = error
        self.blocks = blocks
    }

    private func record(_ call: String) { log.withLock { $0.append(call) } }

    func speechState(for locale: Locale) async -> PackState {
        record("speechState")
        return .installed
    }
    func translationState(from source: Locale.Language) async -> PackState {
        record("translationState")
        return .installed
    }
    func installSpeechPack(for locale: Locale) async throws { record("install") }
    func selfTest(locale: Locale) async throws { record("selfTest") }
    func preflight(locale: Locale) async throws {
        record("preflight \(locale.identifier)")
        entered.open()
        if blocks { await release.wait() }
        try Task.checkCancellation()
        if let error { throw error }
    }
}

@MainActor @Test func aPassingLaunchPreflightGoesStraightToTheCaptionsWithoutASelfTest() async {
    let readiness = PreflightReadiness()
    let route = AppRoute(readiness: readiness)
    #expect(route.page == .launching)
    await route.launch(locale: korean)
    #expect(route.page == .captions)
    #expect(readiness.calls == ["preflight ko-KR"])
}

@MainActor @Test(arguments: [ReadinessFailure.speechPackMissing, .translationPackMissing, .selfTestFailed("x")])
func aFailingLaunchPreflightGoesToTheOnboarding(failure: ReadinessFailure) async {
    let route = AppRoute(readiness: PreflightReadiness(error: failure))
    await route.launch(locale: korean)
    #expect(route.page == .onboarding)
}

@MainActor @Test func anUnexpectedPreflightErrorGoesToTheOnboarding() async {
    let route = AppRoute(readiness: PreflightReadiness(error: FakeError.asr))
    await route.launch(locale: korean)
    #expect(route.page == .onboarding)
}

@MainActor @Test func thePreflightRunsOnlyAtLaunchSoTheUserIsNotSentBack() async {
    let readiness = PreflightReadiness()
    let route = AppRoute(readiness: readiness)
    await route.launch(locale: korean)
    route.showOnboarding()
    await route.launch(locale: korean)
    #expect(route.page == .onboarding)
    #expect(readiness.calls.count == 1)
    route.showCaptions()
    #expect(route.page == .captions)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSecondLaunchWhileThePreflightRunsDoesNothing() async {
    let readiness = PreflightReadiness(blocks: true)
    let route = AppRoute(readiness: readiness)
    let first = Task { await route.launch(locale: korean) }
    await readiness.entered.wait()
    await route.launch(locale: korean)
    #expect(route.page == .launching)
    readiness.release.open()
    await first.value
    #expect(route.page == .captions)
    #expect(readiness.calls.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aLateLaunchResultDoesNotOverrideAPageTheUserMovedTo() async {
    for passes in [true, false] {
        let readiness = PreflightReadiness(error: passes ? nil : FakeError.asr, blocks: true)
        let route = AppRoute(readiness: readiness)
        let launch = Task { await route.launch(locale: korean) }
        await readiness.entered.wait()
        let chosen: AppRoute.Page = passes ? .onboarding : .captions
        if passes { route.showOnboarding() } else { route.showCaptions() }
        readiness.release.open()
        await launch.value
        #expect(route.page == chosen)
    }
}

/// The view's `.task` is cancelled when the view goes away; that must not read as "failed".
@MainActor @Test(.timeLimit(.minutes(1)))
func cancellingTheLaunchingTaskDoesNotTurnThePreflightIntoAFailure() async {
    let readiness = PreflightReadiness(blocks: true)
    let route = AppRoute(readiness: readiness)
    let launch = Task { await route.launch(locale: korean) }
    await readiness.entered.wait()
    launch.cancel()
    readiness.release.open()
    await launch.value
    #expect(route.page == .captions)
}

@MainActor @Test func anAlreadyCancelledCallerStillGetsTheRealAnswer() async {
    let route = AppRoute(readiness: PreflightReadiness())
    let launch = Task { await route.launch(locale: korean) }
    launch.cancel()   // before it starts: this test holds the main actor until the await below
    await launch.value
    #expect(route.page == .captions)
}

@MainActor @Test(arguments: [AppRoute.Page.captions, .onboarding])
func faceToFaceReturnsToWhereItCameFrom(origin: AppRoute.Page) {
    let route = AppRoute(readiness: PreflightReadiness())
    if origin == .captions { route.showCaptions() } else { route.showOnboarding() }
    route.showFaceToFace()
    #expect(route.page == .faceToFace)
    route.showFaceToFace()   // a second tap must not make the page its own origin
    route.closeFaceToFace()
    #expect(route.page == origin)
    route.closeFaceToFace()  // nothing to close
    #expect(route.page == origin)
}

@MainActor @Test func faceToFaceIsNotOpenedWhileLaunching() async {
    let route = AppRoute(readiness: PreflightReadiness())
    route.showFaceToFace()
    #expect(route.page == .launching)
    await route.launch(locale: korean)
    #expect(route.page == .captions)
}

@MainActor @Test func historyOpensFromCaptionsAndReturnsThere() {
    for origin in [AppRoute.Page.captions, .onboarding] {
        let route = AppRoute(readiness: PreflightReadiness())
        if origin == .captions { route.showCaptions() } else { route.showOnboarding() }
        route.showHistory()
        #expect(route.page == .history)
        route.showHistory()      // a second tap must not make the page its own origin
        route.showFaceToFace()   // not offered from the history
        route.closeFaceToFace()
        #expect(route.page == .history)
        route.closeHistory()
        #expect(route.page == origin)
        route.closeHistory()     // nothing to close
        #expect(route.page == origin)
        route.showFaceToFace()
        route.showHistory()      // nor the history from a conversation
        #expect(route.page == .faceToFace)
    }
}

@MainActor @Test func historyIsIgnoredWhileLaunching() async {
    let route = AppRoute(readiness: PreflightReadiness())
    route.showHistory()
    #expect(route.page == .launching)
    await route.launch(locale: korean)
    #expect(route.page == .captions)
}
