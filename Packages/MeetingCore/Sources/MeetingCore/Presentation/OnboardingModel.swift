import Foundation
import Observation

/// The state machine behind the onboarding screen (one source language): checks the two
/// language packs, installs the speech pack, hands the translation pack download to the view,
/// then runs the self-test. It owns no UI. Never starts the translation pack download itself;
/// calls `selfTest` only right after both packs reported `.installed`.
///
/// What the view must do:
/// - Call `refresh()` when the screen appears: nothing is queried until then (the initial
///   `.checking` is idle), and again after a `cancel()` that left `.checking`.
/// - On `.awaitingTranslationDownload`, download the translation pack itself with SwiftUI's
///   `.translationTask` + `prepareTranslation()` (only a view can), then report EXACTLY ONCE
///   through `translationDownloadFinished(error:)`.
/// - Call `cancel()` when the screen disappears (idempotent). Cancelling the task that started
///   a job (e.g. the view's `.task`) also cancels that job, but `.awaitingTranslationDownload`
///   has no job: `cancel()` is the only way out of it, as `refresh()` is ignored there.
///
/// At most one job (refresh, setup, or the continuation after the download) runs at a time; a
/// call that arrives while one runs, or in a step where it does not apply, returns at once and
/// does nothing. A call that arrives while a cancelled job is still ending (an install that
/// ignores cancellation) waits for it first, so jobs never overlap; while waiting it cannot be
/// cancelled into stopping someone else's job, and if its task was cancelled it starts nothing.
@MainActor @Observable public final class OnboardingModel {
    /// Where the onboarding is; the view renders it.
    public enum Step: Equatable, Sendable {
        /// The initial step (idle until `refresh()` is called), and the step while the pack
        /// states are being queried.
        case checking
        /// Setup is needed (or the self-test has not passed yet); `startSetup()` begins it.
        case needsSetup(speech: PackState, translation: PackState)
        /// The speech pack is being installed (`cancel()` stops it).
        case installingSpeech
        /// The view must now download the translation pack (`.translationTask` +
        /// `prepareTranslation()`) and then call `translationDownloadFinished(error:)` once.
        case awaitingTranslationDownload
        /// The self-test runs (`cancel()` stops it; a cancellation is never a failure).
        case selfTesting
        /// Both packs are installed and the self-test passed: usable offline.
        case ready
        /// A readable reason; `retry()` starts over.
        case failed(String)
    }

    /// The current step (observable).
    public internal(set) var step: Step = .checking

    /// The source language of the translation pack the model checks (`locale.language`). The
    /// view MUST build its `TranslationSession.Configuration` with exactly `translationSource`
    /// and `translationTarget`, or its download succeeds while the check still reports the
    /// pack missing.
    public var translationSource: Locale.Language { locale.language }
    /// The fixed target language, Simplified Chinese (`zh-Hans`); see `translationSource`.
    public var translationTarget: Locale.Language { TranslationTarget.language }

    @ObservationIgnored let readiness: any ReadinessChecking
    @ObservationIgnored let locale: Locale
    /// The pack states of the last query: where `cancel()` returns to.
    @ObservationIgnored var known: (speech: PackState, translation: PackState)?
    /// The running job (at most one); cleared by the job itself as its last step. Observed,
    /// so `isBusy` is.
    private var job: Task<Void, Never>?
    /// `job` was cancelled and is only draining (its results are ignored).
    @ObservationIgnored private var jobCancelled = false

    /// True while a job (pack check, setup or self-test) runs, or while a cancelled job is
    /// still draining (an install that ignores cancellation); observable. A call made
    /// meanwhile is ignored or waits, so the view should disable its "下载"/"重试" buttons while
    /// this is true instead of letting a tap wait silently.
    public var isBusy: Bool { job != nil }
    /// Calls waiting for a cancelled job to end before they start (observable, for tests).
    private(set) var callsWaitingForCancelledJob = 0

    /// `locale` is the source language; translation is always into Simplified Chinese.
    public init(readiness: any ReadinessChecking, locale: Locale) {
        self.readiness = readiness
        self.locale = locale
    }

    /// Call when the screen appears. Queries both pack states: either `.unsupported` →
    /// `.failed`; both `.installed` → self-test (`.selfTesting` → `.ready` or `.failed`);
    /// otherwise `.needsSetup`. Ignored while a job runs and during
    /// `.awaitingTranslationDownload`. Cancelling the calling task cancels the job it started.
    public func refresh() async { await run(.check) }

    /// From `.needsSetup` only: installs the speech pack if the state cached in the step says
    /// it is missing (`.installingSpeech`; after a cancelled install that actually completed,
    /// one redundant install is possible), then re-queries: translation pack missing →
    /// `.awaitingTranslationDownload` (the view takes over); both installed → self-test.
    /// Cancelling the calling task cancels the job it started.
    public func startSetup() async { await run(.setUp) }

    /// The view reports its translation pack download here, EXACTLY ONCE per
    /// `.awaitingTranslationDownload`; ignored in any other step (so a report after `cancel()`
    /// is dropped). A `CancellationError` returns to `.needsSetup`; another error fails; success
    /// re-queries both packs and runs the self-test only if both report `.installed`, else fails.
    public func translationDownloadFinished(error: (any Error)?) async {
        await run(.downloadFinished(error))
    }

    /// From `.failed` only: starts over like `refresh()`.
    public func retry() async { await run(.retry) }

    /// Cancels the running install, query or self-test (a cancellation is never a failure) or
    /// stops waiting for the view's download; the step returns to `.needsSetup` with the last
    /// known pack states (`.checking` if none is known yet: call `refresh()` again). The view
    /// must stop its own download too. Does nothing otherwise; safe to call repeatedly.
    public func cancel() {
        if let job, !jobCancelled {
            job.cancel()
            jobCancelled = true
        } else if step != .awaitingTranslationDownload {
            return
        }
        step = stepAfterCancel
    }

    enum Job: Sendable { case check, setUp, downloadFinished((any Error)?), retry }

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
        // A caller whose task was cancelled (e.g. while it waited above) starts nothing.
        guard !Task.isCancelled, accepts(request) else { return }
        let task = Task {
            await perform(request)
            (job, jobCancelled) = (nil, false) // last step: whoever awaits the job sees it idle
        }
        job = task
        jobCancelled = false
        // Only the caller that started the job forwards its cancellation to it.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(task) }
        }
    }

    /// `cancel()`, but only while `task` is still the running, not yet cancelled job.
    private func cancel(_ task: Task<Void, Never>) {
        guard job == task, !jobCancelled else { return }
        cancel()
    }
}
