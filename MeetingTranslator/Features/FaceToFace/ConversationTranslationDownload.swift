import MeetingCore
import SwiftUI
import Translation

/// One download attempt for one direction: its configuration, and the only way it may report.
/// The rules are those of `TranslationDownloadAttempt` (see there).
@MainActor
private final class ConversationDownloadAttempt {
    let configuration: TranslationSession.Configuration
    private let packs: ConversationPacks
    private var reported = false
    private var retired = false

    /// Exactly the pair `packs` checks for `side`.
    init(packs: ConversationPacks, from side: ConversationSide) {
        self.packs = packs
        configuration = TranslationSession.Configuration(
            source: side.translationLanguage, target: side.other.translationLanguage)
    }

    /// The step moved on: a late report of this attempt (its task is being cancelled) must not
    /// reach the model, or it would be taken as the report of the NEXT direction.
    func retire() { retired = true }

    /// At most once and never after `retire()`. In an UNSTRUCTURED task on purpose: the report
    /// runs the follow-up job, which would be cancelled with the `.translationTask` action's
    /// task, and SwiftUI cancels that one as soon as the configuration changes.
    func report(_ error: (any Error)?) {
        guard !reported, !retired else { return }
        reported = true
        let packs = packs
        Task { await packs.translationDownloadFinished(error: error) }
    }
}

/// Downloads the translation pack `packs` is waiting for.
///
/// The attempt is keyed on the awaited SIDE, because the step can go from one direction
/// straight to the other: each value retires the previous attempt and makes a new one. The two
/// configurations differ (the pair is reversed), so `.translationTask` runs again then; the
/// same direction is only awaited again after a step without one, where the configuration is nil.
private struct ConversationTranslationDownload: ViewModifier {
    let packs: ConversationPacks
    @State private var attempt: ConversationDownloadAttempt?

    private var awaited: ConversationSide? {
        if case .awaitingTranslationDownload(let side) = packs.step { side } else { nil }
    }

    func body(content: Content) -> some View {
        let current = attempt
        content
            .onChange(of: awaited, initial: true) { _, side in
                attempt?.retire()
                attempt = side.map { ConversationDownloadAttempt(packs: packs, from: $0) }
            }
            .translationTask(current?.configuration, action: Self.action(for: current))
    }

    /// Nonisolated so the non-Sendable session stays in its own region. A thrown error (also a
    /// download the user dismisses) is reported; a cancelled task reports a cancellation.
    private nonisolated static func action(
        for attempt: ConversationDownloadAttempt?
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
    func conversationTranslationDownload(for packs: ConversationPacks) -> some View {
        modifier(ConversationTranslationDownload(packs: packs))
    }
}
