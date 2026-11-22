import Foundation
import Observation

/// The state machine behind the onboarding screen (one source language): checks the two
/// language packs, installs the speech pack, hands the translation pack download to the view,
/// then runs the self-test. It owns no UI.
///
/// At most one job (refresh, setup, or the continuation after the view's download) runs at a
/// time; a call that arrives while one is running, or in a step where it does not apply, does
/// nothing. After `cancel()` the next call first waits for the cancelled job to end, so two jobs
/// never overlap. The model never starts the translation pack download itself and only calls
/// `selfTest` right after both packs reported `.installed`.
@MainActor @Observable public final class OnboardingModel {
    public enum Step: Equatable, Sendable {
        /// Querying the pack states.
        case checking
        /// Setup is needed (or the self-test has not passed yet); `startSetup()` begins it.
        case needsSetup(speech: PackState, translation: PackState)
        case installingSpeech
        /// The view must now download the translation pack (`.translationTask` +
        /// `prepareTranslation()`) and then call `translationDownloadFinished(error:)`.
        case awaitingTranslationDownload
        case selfTesting
        /// Both packs are installed and the self-test passed: usable offline.
        case ready
        /// A readable reason; `retry()` starts over.
        case failed(String)
    }

    public private(set) var step: Step = .checking

    @ObservationIgnored private let readiness: any ReadinessChecking
    @ObservationIgnored private let locale: Locale
    /// The pack states of the last query: where `cancel()` returns to.
    @ObservationIgnored private var known: (speech: PackState, translation: PackState)?
    /// The running job (at most one); cleared by the job itself as its last step.
    @ObservationIgnored private var job: Task<Void, Never>?
    /// `job` was cancelled and is only draining (its results are ignored).
    @ObservationIgnored private var jobCancelled = false

    /// A job is running or draining (for tests).
    var isBusy: Bool { job != nil }
    /// Calls waiting for a cancelled job to end before they start (observable, for tests).
    private(set) var callsWaitingForCancelledJob = 0

    /// `locale` is the source language; translation is always into Simplified Chinese.
    public init(readiness: any ReadinessChecking, locale: Locale) {
        self.readiness = readiness
        self.locale = locale
    }

    /// Queries both pack states: either `.unsupported` → `.failed`; both `.installed` → runs the
    /// self-test (`.selfTesting` → `.ready` or `.failed`); otherwise `.needsSetup`. Ignored while
    /// a job runs and while the view downloads the translation pack.
    public func refresh() async { await run(.check) }

    /// From `.needsSetup` only: installs the speech pack if needed (`.installingSpeech`), then
    /// re-queries: translation pack missing → `.awaitingTranslationDownload` (the view takes
    /// over); both installed → self-test.
    public func startSetup() async { await run(.setUp) }

    /// From `.awaitingTranslationDownload` only; the view calls it when its download ended.
    /// An error fails (a `CancellationError` returns to `.needsSetup`); success re-queries the
    /// packs and runs the self-test only if both report `.installed`, else fails.
    public func translationDownloadFinished(error: (any Error)?) async {
        await run(.downloadFinished(error))
    }

    /// From `.failed` only: starts over like `refresh()`.
    public func retry() async { await run(.retry) }

    /// Cancels the running install, query or self-test (a cancellation is never a failure) or
    /// stops waiting for the view's download; the step returns to `.needsSetup` with the last
    /// known pack states (`.checking` if none is known yet; `refresh()` re-queries). The view
    /// must stop its own download too. Does nothing otherwise; safe to call twice.
    public func cancel() {
        if let job, !jobCancelled {
            job.cancel()
            jobCancelled = true
        } else if step != .awaitingTranslationDownload {
            return
        }
        step = stepAfterCancel
    }

    private enum Job: Sendable { case check, setUp, downloadFinished((any Error)?), retry }

    private func accepts(_ request: Job) -> Bool {
        switch (request, step) {
        case (.check, .awaitingTranslationDownload): false
        case (.check, _), (.setUp, .needsSetup), (.downloadFinished, .awaitingTranslationDownload),
             (.retry, .failed): true
        default: false
        }
    }

    private func run(_ request: Job) async {
        while let running = job {
            guard jobCancelled else { return } // a live job is running: ignore this call
            callsWaitingForCancelledJob += 1
            await running.value
            callsWaitingForCancelledJob -= 1
        }
        guard accepts(request) else { return }
        let task = Task {
            await perform(request)
            (job, jobCancelled) = (nil, false) // last step: whoever awaits the job sees it idle
        }
        job = task
        jobCancelled = false
        await task.value
    }

    private func perform(_ request: Job) async {
        switch request {
        case .check, .retry: await check()
        case .setUp: await setUp()
        case .downloadFinished(let error?): settle(error, UserMessages.translationDownloadFailed(error))
        case .downloadFinished(nil): await proceed(afterDownload: true)
        }
    }

    private func check() async {
        step = .checking
        guard let states = await query() else { return }
        if let message = unsupported(states) { step = .failed(message) }
        else if states.speech == .installed, states.translation == .installed {
            await selfTest()
        } else {
            step = .needsSetup(speech: states.speech, translation: states.translation)
        }
    }

    private func setUp() async {
        guard case .needsSetup(let speech, _) = step else { return }
        if speech != .installed {
            step = .installingSpeech
            do {
                try await readiness.installSpeechPack(for: locale)
            } catch {
                return settle(error, UserMessages.speechInstallFailed(error))
            }
            guard !Task.isCancelled else { return }
        }
        await proceed(afterDownload: false)
    }

    /// Re-queries after the speech install or the view's download; never calls `selfTest`
    /// unless both packs report `.installed`.
    private func proceed(afterDownload: Bool) async {
        guard let states = await query() else { return }
        if let message = unsupported(states) { step = .failed(message) }
        else if states.speech != .installed {
            step = .failed(UserMessages.stillMissing(UserMessages.speechPack))
        } else if states.translation != .installed {
            step = afterDownload ? .failed(UserMessages.stillMissing(UserMessages.translationPack))
                : .awaitingTranslationDownload
        } else {
            await selfTest()
        }
    }

    private func selfTest() async {
        step = .selfTesting
        do {
            try await readiness.selfTest(locale: locale)
        } catch {
            return settle(error, UserMessages.selfTestFailed(error))
        }
        guard !Task.isCancelled else { return }
        step = .ready
    }

    /// Both pack states, or nil when the job was cancelled meanwhile.
    private func query() async -> (speech: PackState, translation: PackState)? {
        let speech = await readiness.speechState(for: locale)
        guard !Task.isCancelled else { return nil }
        let translation = await readiness.translationState(from: locale.language)
        guard !Task.isCancelled else { return nil }
        known = (speech, translation)
        return (speech, translation)
    }

    private func unsupported(_ states: (speech: PackState, translation: PackState)) -> String? {
        if states.speech == .unsupported { return UserMessages.speechUnsupported(locale) }
        if states.translation == .unsupported { return UserMessages.translationUnsupported(locale) }
        return nil
    }

    /// Ends a job on `error`: a cancelled job changes nothing (`cancel()` already set the step);
    /// a `CancellationError` is never a failure; anything else fails with `message`.
    private func settle(_ error: any Error, _ message: String) {
        guard !Task.isCancelled else { return }
        step = error is CancellationError ? stepAfterCancel : .failed(message)
    }

    private var stepAfterCancel: Step {
        known.map { .needsSetup(speech: $0.speech, translation: $0.translation) } ?? .checking
    }
}
