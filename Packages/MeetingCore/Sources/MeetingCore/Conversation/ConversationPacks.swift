import Foundation
import Observation

/// What `ConversationPacks` needs from the system; `ModelReadiness` provides it.
public protocol ConversationPackChecking: Sendable {
    func speechState(for locale: Locale) async -> PackState
    func translationState(from: Locale.Language, to: Locale.Language) async -> PackState
    func installSpeechPack(for locale: Locale) async throws
}

/// One of the four language packs of a face-to-face conversation.
public enum ConversationPack: Equatable, Hashable, Sendable {
    /// Speech recognition of `side.speechLocale`.
    case speech(ConversationSide)
    /// Translation from `from.translationLanguage` to `from.other.translationLanguage`.
    case translation(from: ConversationSide)

    /// All four, in the order they are listed and fetched.
    static let all: [ConversationPack] = ConversationSide.allCases.map { .speech($0) }
        + ConversationSide.allCases.map { .translation(from: $0) }
}

/// Checks and fetches the four language packs of the face-to-face screen: installs the speech
/// packs itself, then hands each missing translation pack download to the view. It owns no UI.
///
/// What the view must do:
/// - Call `refresh()` when the screen appears (the initial `.checking` is idle), and again
///   after a `cancel()` that left `.checking`. It also starts over from `.failed`.
/// - On `.awaitingTranslationDownload(from: side)`, download the pack from exactly
///   `side.translationLanguage` to `side.other.translationLanguage` with `.translationTask` +
///   `prepareTranslation()`, then report EXACTLY ONCE through
///   `translationDownloadFinished(error:)`, from an unstructured `Task`: SwiftUI cancels the
///   `.translationTask` action's task, which would cancel the follow-up job. A second
///   `.awaitingTranslationDownload` (the other direction) needs a new configuration.
/// - Call `cancel()` when the screen disappears (idempotent). It is the only way out of
///   `.awaitingTranslationDownload`, which has no job.
///
/// At most one job (refresh, download, or the continuation after a report) runs at a time; a
/// call that arrives while one runs, or in a step where it does not apply, does nothing. A
/// call that arrives while a cancelled job is still ending (an install that ignores
/// cancellation) waits for it first. Cancelling the task that started a job cancels the job.
@MainActor @Observable public final class ConversationPacks {
    public enum Step: Equatable, Sendable {
        case checking
        /// The packs still to fetch, in order; `download()` begins.
        case missing([ConversationPack])
        case installing(ConversationPack)
        case awaitingTranslationDownload(from: ConversationSide)
        case ready
        /// A readable reason; `refresh()` starts over.
        case failed(String)
    }

    // `public internal(set)`: the `+Jobs` extension writes it.
    public internal(set) var step: Step = .checking

    @ObservationIgnored let checking: any ConversationPackChecking
    /// The pack states of the last full query: where `cancel()` returns to.
    @ObservationIgnored var known: [ConversationPack: PackState]?
    /// The running job (at most one); cleared by the job itself as its last step. Observed,
    /// so `isBusy` is.
    private var job: Task<Void, Never>?
    /// `job` was cancelled and is only draining (its results are ignored).
    @ObservationIgnored private var jobCancelled = false

    /// True while a job runs or a cancelled one is still draining; the view should disable
    /// its buttons meanwhile.
    public var isBusy: Bool { job != nil }
    /// Calls waiting for a cancelled job to end (observable, for tests).
    private(set) var callsWaitingForCancelledJob = 0

    public init(checking: any ConversationPackChecking) {
        self.checking = checking
    }

    /// Queries all four packs: any unsupported → `.failed`; all installed → `.ready`; else
    /// `.missing`. Ignored during `.awaitingTranslationDownload`.
    public func refresh() async { await run(.check) }

    /// From `.missing` only: installs the missing speech packs (Chinese, then Korean), then
    /// asks the view for the first missing translation pack.
    public func download() async { await run(.download) }

    /// The view's report for the awaited pair; ignored in any other step. A
    /// `CancellationError` returns to `.missing`; another error fails; success re-queries and
    /// fails if that pair is still not installed, else goes on to the next missing pack.
    public func translationDownloadFinished(error: (any Error)?) async {
        await run(.downloadFinished(error))
    }

    /// Cancels the running job (a cancellation is never a failure) or stops waiting for the
    /// view's download; returns to `.missing` with what is still missing (`.checking` if
    /// nothing is known yet). Does nothing otherwise.
    public func cancel() {
        if let job, !jobCancelled {
            job.cancel()
            jobCancelled = true
        } else if !isAwaitingDownload {
            return
        }
        step = settled
    }

    enum Job: Sendable { case check, download, downloadFinished((any Error)?) }

    private var isAwaitingDownload: Bool {
        if case .awaitingTranslationDownload = step { true } else { false }
    }

    private func accepts(_ request: Job) -> Bool {
        switch (request, step) {
        case (.check, .awaitingTranslationDownload): false
        case (.check, _), (.download, .missing),
             (.downloadFinished, .awaitingTranslationDownload): true
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
        // Only the caller that started the job forwards its cancellation to it. Built here,
        // on the main actor, so `onCancel` captures only this Sendable closure.
        let forwardCancel: @MainActor @Sendable () -> Void = { [weak self] in self?.cancel(task) }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in forwardCancel() }
        }
    }

    /// `cancel()`, but only while `task` is still the running, not yet cancelled job.
    private func cancel(_ task: Task<Void, Never>) {
        guard job == task, !jobCancelled else { return }
        cancel()
    }
}
