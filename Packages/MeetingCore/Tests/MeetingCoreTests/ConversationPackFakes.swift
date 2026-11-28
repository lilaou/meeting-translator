import Foundation
import Synchronization
@testable import MeetingCore

/// The four packs with `partner`, in the order the model lists them.
func packList(_ partner: ConversationSide) -> [ConversationPack] {
    [.speech(.chinese), .speech(partner), .translation(from: .chinese), .translation(from: partner)]
}

let allPacks = packList(.korean)

/// Scripted `ConversationPackChecking` for Chinese and one `partner`. A pack is recognized only
/// by the exact locale or pair of its side; any other query reports `.unsupported`. A successful
/// install makes the speech pack `.installed` (unless `installDoesNothing`).
///
/// With `installGate`, installs wait for it; `installEntered` opens when one starts. With
/// `honorsCancellation` a cancelled install stops waiting and throws `CancellationError`.
final class ScriptedPacks: ConversationPackChecking, Sendable {
    private struct State {
        var packs: [ConversationPack: PackState]
        var installed: [String] = []
        var queries = 0
        var pairs: [[Locale.Language]] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    private let state: Mutex<State>
    private let partner: ConversationSide
    private var sides: [ConversationSide] { [.chinese, partner] }
    private let installError: (any Error)?
    private let installDoesNothing: Bool
    private let honorsCancellation: Bool
    private let installGate: Gate?
    let installEntered = Gate()

    /// Every pack not named in `states` is `.installed`.
    init(_ states: [ConversationPack: PackState] = [:], partner: ConversationSide = .korean,
         installError: (any Error)? = nil,
         installDoesNothing: Bool = false, installGate: Gate? = nil, honorsCancellation: Bool = true) {
        var packs = Dictionary(uniqueKeysWithValues: packList(partner).map { ($0, PackState.installed) })
        packs.merge(states) { _, new in new }
        state = Mutex(State(packs: packs))
        self.partner = partner
        self.installError = installError
        self.installDoesNothing = installDoesNothing
        self.installGate = installGate
        self.honorsCancellation = honorsCancellation
    }

    /// Every pack missing.
    static func empty(partner: ConversationSide = .korean, installGate: Gate? = nil,
                      honorsCancellation: Bool = true) -> ScriptedPacks {
        ScriptedPacks(Dictionary(uniqueKeysWithValues: packList(partner).map { ($0, .notInstalled) }),
                      partner: partner, installGate: installGate,
                      honorsCancellation: honorsCancellation)
    }

    /// The locale identifiers of every install, in order.
    var installed: [String] { state.withLock { $0.installed } }
    var queries: Int { state.withLock { $0.queries } }
    /// The [from, to] of every translation query, in order.
    var translationPairs: [[Locale.Language]] { state.withLock { $0.pairs } }
    var maxInstallsInFlight: Int { state.withLock { $0.maxInFlight } }
    /// Plays the view (or the system) changing a pack.
    func set(_ pack: ConversationPack, _ value: PackState) { state.withLock { $0.packs[pack] = value } }

    func conversationSpeechState(for locale: Locale) async -> PackState {
        report(sides.first { $0.speechLocale == locale }.map { .speech($0) })
    }

    func translationState(from: Locale.Language, to: Locale.Language) async -> PackState {
        state.withLock { $0.pairs.append([from, to]) }
        let side = sides.first {
            $0.translationLanguage == from
                && $0.counterpart(partner: partner).translationLanguage == to
        }
        return report(side.map { .translation(from: $0) })
    }

    private func report(_ pack: ConversationPack?) -> PackState {
        state.withLock { s in
            s.queries += 1
            return pack.flatMap { s.packs[$0] } ?? .unsupported
        }
    }

    func installSpeechPack(for locale: Locale) async throws {
        state.withLock { s in
            s.installed.append(locale.identifier)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        installEntered.open()
        if let installGate {
            if honorsCancellation {
                await withTaskCancellationHandler { await installGate.wait() } onCancel: { installGate.open() }
                try Task.checkCancellation()
            } else {
                await installGate.wait()
            }
        }
        if let installError { throw installError }
        guard !installDoesNothing,
              let side = sides.first(where: { $0.speechLocale == locale }) else { return }
        set(.speech(side), .installed)
    }
}
