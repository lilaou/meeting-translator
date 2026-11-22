import Foundation
import Synchronization
@testable import MeetingCore

/// Scripted `ReadinessChecking` for the onboarding model. Pack states can change (after a
/// successful `installSpeechPack`, or when a test plays the view and "downloads" the
/// translation pack); install and self-test errors are configurable. Records every call, how
/// many calls are in flight (and the most ever at once), and every `selfTest` that started
/// while a pack did not report `.installed`.
///
/// Calls listed in `blocking` wait until the test calls `release(_:)` for them (one gate per
/// kind of call: once released, later calls of that kind pass straight through). With
/// `honorsCancellation` (default) a cancelled call opens its gate and throws
/// `CancellationError`; without it, the call keeps waiting until the test releases it.
final class ScriptedReadiness: ReadinessChecking, Sendable {
    enum Call: Sendable, Hashable { case speechState, translationState, install, selfTest, preflight }

    private struct State {
        var speech: PackState
        var translation: PackState
        var speechAfterInstall: PackState
        var installError: (any Error)?
        var selfTestErrors: [any Error]
        var log: [Call] = []
        var inFlight = 0
        var maxInFlight = 0
        var selfTestsBeforeInstalled = 0
    }

    private let state: Mutex<State>
    private let blocking: Set<Call>
    private let honorsCancellation: Bool
    private let entries: [Call: Gate]
    private let releases: [Call: Gate]

    init(speech: PackState, translation: PackState, speechAfterInstall: PackState = .installed,
         installError: (any Error)? = nil, selfTestErrors: [any Error] = [],
         blocking: Set<Call> = [], honorsCancellation: Bool = true) {
        state = Mutex(State(speech: speech, translation: translation,
                            speechAfterInstall: speechAfterInstall, installError: installError,
                            selfTestErrors: selfTestErrors))
        self.blocking = blocking
        self.honorsCancellation = honorsCancellation
        let all: [Call] = [.speechState, .translationState, .install, .selfTest, .preflight]
        entries = Dictionary(uniqueKeysWithValues: all.map { ($0, Gate()) })
        releases = Dictionary(uniqueKeysWithValues: all.map { ($0, Gate()) })
    }

    var calls: [Call] { state.withLock { $0.log } }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
    var inFlight: Int { state.withLock { $0.inFlight } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var selfTestsBeforeInstalled: Int { state.withLock { $0.selfTestsBeforeInstalled } }

    /// Plays the view: the translation pack's reported state after its download.
    func setTranslation(_ value: PackState) { state.withLock { $0.translation = value } }
    func setSpeech(_ value: PackState) { state.withLock { $0.speech = value } }

    /// Lets blocked (and later) calls of this kind go on.
    func release(_ call: Call) { releases[call]!.open() }

    /// Suspends until `call` has been entered at least once.
    func entered(_ call: Call) async { await entries[call]!.wait() }

    func speechState(for locale: Locale) async -> PackState {
        begin(.speechState)
        defer { end() }
        try? await pass(.speechState)
        return state.withLock { $0.speech }
    }

    func translationState(from source: Locale.Language) async -> PackState {
        begin(.translationState)
        defer { end() }
        try? await pass(.translationState)
        return state.withLock { $0.translation }
    }

    func installSpeechPack(for locale: Locale) async throws {
        begin(.install)
        defer { end() }
        try await pass(.install)
        try state.withLock { s in
            if let error = s.installError { throw error }
            s.speech = s.speechAfterInstall
        }
    }

    func selfTest(locale: Locale) async throws {
        begin(.selfTest)
        defer { end() }
        state.withLock { s in
            if s.speech != .installed || s.translation != .installed { s.selfTestsBeforeInstalled += 1 }
        }
        try await pass(.selfTest)
        let error = state.withLock { s in s.selfTestErrors.isEmpty ? nil : s.selfTestErrors.removeFirst() }
        if let error { throw error }
    }

    func preflight(locale: Locale) async throws {
        begin(.preflight)
        end()
    }

    private func begin(_ call: Call) {
        state.withLock { s in
            s.log.append(call)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
        }
        entries[call]!.open()
    }

    private func end() { state.withLock { $0.inFlight -= 1 } }

    /// Waits at `release` when `call` is blocking (see the type's doc).
    private func pass(_ call: Call) async throws {
        guard blocking.contains(call) else { return }
        let release = releases[call]!
        guard honorsCancellation else { return await release.wait() }
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            release.open()
        }
        try Task.checkCancellation()
    }
}
