// TranslationSession(installedSource:target:) exists from the iOS 26 / macOS 26 SDKs on,
// which ship with Swift 6.2; older toolchains (and their SDKs) compile the package without
// this file.
#if compiler(>=6.2)
import Foundation
import Translation

/// `Translator` on Apple's on-device Translation framework, into the one target language each
/// instance is made with (Simplified Chinese for the meeting captions, `init()`).
/// Only installed language packs are used: downloading them needs SwiftUI's
/// `.translationTask`, so it happens in the app's onboarding, not here. Without an installed
/// pack every call throws `AppleTranslatorError.packNotInstalled` at once.
///
/// One session per source language is cached in an actor (the target never changes), so calls
/// may come from any context; the actor runs them one at a time. `context` is ignored.
///
/// Because calls are serialized, a translation call that never returned would still block
/// every later call on the same `AppleTranslator` value, including `selfTest`'s translation if
/// the app shares one instance. Apple documents that the session throws instead of waiting, so
/// the risk is low. The coordinator no longer waits for it at the end of a meeting: its drains
/// are bounded (`PipelineConfig.engineDrainTimeout` 10 s, `translationDrainTimeout` 30 s, both
/// provisional; see docs/superpowers/notes/2026-11-21-engine-contracts.md).
///
/// Unverified without a device: that a session made with installed packs works offline and
/// throws (instead of waiting) when the app is in the background or the pack was removed,
/// that batch answers carry the request identifiers, and the translation quality.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleTranslator: Translator {
    private let target: Locale.Language
    private let sessions: TranslationSessions

    /// Translates into Simplified Chinese.
    public init() {
        self.init(target: TranslationTarget.language)
    }

    public init(target: Locale.Language) {
        self.target = target
        sessions = TranslationSessions(target: target)
    }

    public func canTranslate(from source: Locale.Language) async -> Bool {
        await Self.packState(from: source, to: target) == .installed
    }

    /// Throws instead of returning an empty or blank translation.
    public func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        let results = try await sessions.translate([text], from: source)
        guard let result = results.first else { throw AppleTranslatorError.mismatchedResults }
        return result
    }

    /// One result per text, in input order; any failure throws for the whole batch.
    public func translateBatch(_ texts: [String], from source: Locale.Language,
                               context: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        return try await sessions.translate(texts, from: source)
    }

    /// The state of the pack from `source` to `target`.
    static func packState(from source: Locale.Language, to target: Locale.Language) async -> PackState {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .notInstalled
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }
}

/// Owns the cached sessions and makes every call on them, one call at a time (in arrival
/// order), so a session is never used by two calls at once.
@available(iOS 26.0, macOS 26.0, *)
actor TranslationSessions {
    private let target: Locale.Language
    private var cache: [String: TranslationSession] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Locale.Language) {
        self.target = target
    }

    func translate(_ texts: [String], from source: Locale.Language) async throws -> [String] {
        await acquire()
        defer { release() }
        let key = source.maximalIdentifier
        // `TranslationSession` is not Sendable and its methods run off this actor. Calls are
        // serialized above, so only this call uses the session until it returns.
        nonisolated(unsafe) let session = try await cachedSession(for: source, key: key)
        let requests = texts.indices.map {
            TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
        }
        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            // A failed session may be unusable (e.g. the pack was removed); start afresh next time.
            cache[key] = nil
            throw AppleTranslatorError.wrapping(error)
        }
        let answers = responses.map { TranslatedText(identifier: $0.clientIdentifier, text: $0.targetText) }
        return try orderedTranslations(answers, count: texts.count)
    }

    private func cachedSession(for source: Locale.Language, key: String) async throws -> TranslationSession {
        if let cached = cache[key] { return cached }
        guard await AppleTranslator.packState(from: source, to: target) == .installed else {
            throw AppleTranslatorError.packNotInstalled(source.minimalIdentifier,
                                                       target: target.minimalIdentifier)
        }
        let session = TranslationSession(installedSource: source, target: target)
        cache[key] = session
        return session
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the turn to the next waiting call, if any.
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
#endif
