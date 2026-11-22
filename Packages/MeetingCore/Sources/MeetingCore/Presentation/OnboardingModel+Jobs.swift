import Foundation

// The bodies of the onboarding jobs. Each runs inside the one job task that `run(_:)` starts;
// every step write after an `await` is skipped once the job was cancelled (`cancel()` has
// already set the step then). All on the main actor, so a check and its write never interleave
// with `cancel()`.
extension OnboardingModel {
    func perform(_ request: Job) async {
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
        if let message = unsupported(states) {
            step = .failed(message)
        } else if states.speech == .installed, states.translation == .installed {
            await selfTest()
        } else {
            step = .needsSetup(speech: states.speech, translation: states.translation)
        }
    }

    /// Uses the speech state cached in `.needsSetup` (no re-query before installing).
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
        if let message = unsupported(states) {
            step = .failed(message)
        } else if states.speech != .installed {
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

    /// Where a cancel returns to: `.needsSetup` with the last known states, else `.checking`.
    var stepAfterCancel: Step {
        known.map { .needsSetup(speech: $0.speech, translation: $0.translation) } ?? .checking
    }
}
