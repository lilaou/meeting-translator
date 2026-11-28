import Foundation

// The bodies of the pack jobs. Each runs inside the one job task that `run(_:)` starts; every
// step write after an `await` is skipped once the job was cancelled (`cancel()` has already
// set the step then). All on the main actor, so a check and its write never interleave with
// `cancel()`.
extension ConversationPacks {
    func perform(_ request: Job) async {
        switch request {
        case .check:
            step = .checking
            if await query() { step = settled }
        case .download: await installAndContinue()
        case .downloadFinished(let error?):
            settle(error, UserMessages.translationDownloadFailed(error))
        case .downloadFinished(nil): await confirmDownload()
        }
    }

    private func installAndContinue() async {
        while case .missing(let packs) = settled, case .speech(let side) = packs.first {
            step = .installing(.speech(side))
            do {
                try await checking.installSpeechPack(for: side.speechLocale)
            } catch {
                return settle(error, UserMessages.speechInstallFailed(error))
            }
            guard !Task.isCancelled, await query() else { return }
            guard known?[.speech(side)] == .installed else {
                return step = .failed(UserMessages.stillMissing(UserMessages.speechPack))
            }
        }
        proceed()
    }

    private func confirmDownload() async {
        guard case .awaitingTranslationDownload(let side) = step, await query() else { return }
        if known?[.translation(from: side)] == .notInstalled {
            step = .failed(UserMessages.stillMissing(UserMessages.translationPack))
        } else if case .missing(let packs) = settled, case .speech = packs.first {
            step = .failed(UserMessages.stillMissing(UserMessages.speechPack))
        } else {
            proceed()
        }
    }

    /// With no speech pack missing: asks the view for the first missing translation pack, or
    /// ends in `.ready` or `.failed`.
    private func proceed() {
        if case .missing(let packs) = settled, case .translation(let side) = packs.first {
            step = .awaitingTranslationDownload(from: side)
        } else {
            step = settled
        }
    }

    /// Queries all four packs into `known`; false (and `known` kept) when the job was
    /// cancelled meanwhile.
    private func query() async -> Bool {
        var states: [ConversationPack: PackState] = [:]
        for pack in all {
            switch pack {
            case .speech(let side):
                states[pack] = await checking.conversationSpeechState(for: side.speechLocale)
            case .translation(let side):
                states[pack] = await checking.translationState(from: side.translationLanguage,
                                                               to: target(from: side).translationLanguage)
            }
            guard !Task.isCancelled else { return false }
        }
        known = states
        return true
    }

    /// The idle step for the last known states (also where a cancel returns to): `.checking`
    /// when none are known.
    var settled: Step {
        guard let known else { return .checking }
        if let pack = all.first(where: { known[$0] == .unsupported }) {
            return .failed(unsupported(pack))
        }
        let missing = all.filter { known[$0] != .installed }
        return missing.isEmpty ? .ready : .missing(missing)
    }

    private func unsupported(_ pack: ConversationPack) -> String {
        switch pack {
        case .speech(let side):
            UserMessages.speechUnsupported(side.speechLocale)
        case .translation(let side):
            UserMessages.translationUnsupported(from: side.speechLocale,
                                                to: target(from: side).speechLocale)
        }
    }

    /// Ends a job on `error`: a cancelled job changes nothing (`cancel()` already set the
    /// step); a `CancellationError` is never a failure; anything else fails with `message`.
    private func settle(_ error: any Error, _ message: String) {
        guard !Task.isCancelled else { return }
        step = error is CancellationError ? settled : .failed(message)
    }
}
