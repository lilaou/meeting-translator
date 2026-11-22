import MeetingCore
import SwiftUI
import Translation

/// One download attempt: the configuration SwiftUI's `.translationTask` is given, and the only
/// way the attempt may report back to the model.
@MainActor
final class TranslationDownloadAttempt {
    let configuration: TranslationSession.Configuration
    private let onboarding: OnboardingModel
    private var reported = false
    private var retired = false

    init(onboarding: OnboardingModel) {
        self.onboarding = onboarding
        // Obligation 11: the language pair comes only from the model, nothing else is set.
        configuration = TranslationSession.Configuration(
            source: onboarding.translationSource, target: onboarding.translationTarget)
    }

    /// The step left `.awaitingTranslationDownload`: a late report of this attempt (its task
    /// is being cancelled) must not reach the model, or it could end a NEWER attempt.
    func retire() { retired = true }

    /// Reports to the model at most once, and never after `retire()`.
    func report(_ error: (any Error)?) async {
        guard !reported, !retired else { return }
        reported = true
        await onboarding.translationDownloadFinished(error: error)
    }
}

/// Downloads the translation pack while `onboarding.step == .awaitingTranslationDownload`
/// (only a view can: `.translationTask` + `prepareTranslation()`).
///
/// - Obligation 9: the configuration is DERIVED from the step. Each time the step enters the
///   state a NEW attempt (a new `Configuration`) is created, and it is set to nil when the
///   step leaves, so the next entry makes `.translationTask` run again (an unchanged
///   configuration would not).
/// - Obligation 10: `translationDownloadFinished(error:)` is called EXACTLY ONCE per attempt on
///   every path. The one call site is after the do/catch in the task closure, which computes the outcome:
///   success is nil, a thrown error is that error, and cancellation (a `CancellationError`, or
///   the task being cancelled at all) is `CancellationError()`, which the model reads as
///   "back to needsSetup" and not as a failure. `TranslationDownloadAttempt.report` also
///   refuses a second report.
/// - Obligation 11: the pair is `translationSource`/`translationTarget`, else the download
///   succeeds while the model's check still says the pack is missing.
struct TranslationDownloadModifier: ViewModifier {
    let onboarding: OnboardingModel
    @State private var attempt: TranslationDownloadAttempt?

    private var isAwaiting: Bool { onboarding.step == .awaitingTranslationDownload }

    func body(content: Content) -> some View {
        let current = attempt
        content
            .onChange(of: isAwaiting, initial: true) { _, awaiting in
                attempt?.retire()
                attempt = awaiting ? TranslationDownloadAttempt(onboarding: onboarding) : nil
            }
            .translationTask(current?.configuration, action: Self.action(for: current))
    }

    /// Built in a nonisolated context on purpose: a closure written inline in `body` would be
    /// main-actor isolated, and Swift 6 then rejects sending the (non-Sendable) session to
    /// `prepareTranslation()`. This one keeps the session in its own region.
    private nonisolated static func action(
        for attempt: TranslationDownloadAttempt?
    ) -> @Sendable (TranslationSession) async -> Void {
        { session in
            guard let attempt else { return }
            let outcome: (any Error)?
            do {
                try await session.prepareTranslation()
                outcome = Task.isCancelled ? CancellationError() : nil
            } catch is CancellationError {
                outcome = CancellationError()
            } catch {
                outcome = Task.isCancelled ? CancellationError() : error
            }
            await attempt.report(outcome)
        }
    }
}

extension View {
    func translationDownload(for onboarding: OnboardingModel) -> some View {
        modifier(TranslationDownloadModifier(onboarding: onboarding))
    }
}
