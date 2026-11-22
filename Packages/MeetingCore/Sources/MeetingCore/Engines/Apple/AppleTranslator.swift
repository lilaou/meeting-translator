// TranslationSession(installedSource:target:) exists from the iOS 26 / macOS 26 SDKs on,
// which ship with Swift 6.2; older toolchains (and their SDKs) compile the package without
// this file.
#if compiler(>=6.2)
import Foundation
import Translation

/// `Translator` on Apple's on-device Translation framework, always into Simplified Chinese.
/// Only installed language packs are used: downloading them needs SwiftUI's
/// `.translationTask`, so it happens in the app's onboarding, not here. Without an installed
/// pack every call throws `AppleTranslatorError.packNotInstalled` at once.
///
/// One session per source language is cached in an actor, so calls may come from any
/// context. `context` is ignored.
///
/// Unverified without a device: that a session made with installed packs works offline and
/// throws (instead of waiting) when the app is in the background or the pack was removed,
/// that batch answers carry the request identifiers, and the translation quality.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleTranslator: Translator {
    /// The spec's fixed target language.
    static let target = Locale.Language(identifier: "zh-Hans")

    private let sessions = TranslationSessions()

    public init() {}

    public func canTranslate(from source: Locale.Language) async -> Bool {
        await Self.packState(from: source) == .installed
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

    /// The state of the pack from `source` to Simplified Chinese.
    static func packState(from source: Locale.Language) async -> PackState {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .notInstalled
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }
}

/// Owns the cached sessions and makes every call on them.
@available(iOS 26.0, macOS 26.0, *)
actor TranslationSessions {
    private var cache: [String: TranslationSession] = [:]

    func translate(_ texts: [String], from source: Locale.Language) async throws -> [String] {
        let key = source.maximalIdentifier
        let session = try await session(for: source, key: key)
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

    private func session(for source: Locale.Language, key: String) async throws -> TranslationSession {
        if let cached = cache[key] { return cached }
        guard await AppleTranslator.packState(from: source) == .installed else {
            throw AppleTranslatorError.packNotInstalled(source.minimalIdentifier)
        }
        // Another call may have made one while this one waited.
        if let cached = cache[key] { return cached }
        let session = TranslationSession(installedSource: source, target: AppleTranslator.target)
        cache[key] = session
        return session
    }
}
#endif
