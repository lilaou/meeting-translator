import AVFoundation
import Foundation
import Synchronization
@testable import MeetingCore

enum FakeError: Error, Equatable { case translation, asr }

struct FakeASREngine: ASREngine {
    let events: [ASREvent]
    let error: Error?

    init(events: [ASREvent], error: Error? = nil) {
        self.events = events
        self.error = error
    }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }

    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error> {
        let events = events, error = error
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish(throwing: error)
        }
    }
}

final class FakeTranslator: Translator, Sendable {
    private let failing: Set<String>
    private let delay: Duration
    private let sizes = Mutex<[Int]>([])
    private let batchCtx = Mutex<[[String]]>([])
    private let singleCtx = Mutex<[[String]]>([])

    init(failing: Set<String> = [], delay: Duration = .zero) {
        self.failing = failing
        self.delay = delay
    }

    /// Size of every translateBatch call, in call order.
    var batchSizes: [Int] { sizes.withLock { $0 } }
    /// `context` received by every translateBatch call, in call order.
    var contexts: [[String]] { batchCtx.withLock { $0 } }
    /// `context` received by every direct (non-batch) translate call, in call order.
    var singleContexts: [[String]] { singleCtx.withLock { $0 } }

    func canTranslate(from source: Locale.Language) async -> Bool { true }

    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        singleCtx.withLock { $0.append(context) }
        return try await translateOne(text)
    }

    /// Throws without translating anything when any text in the batch is in `failing`.
    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String] {
        sizes.withLock { $0.append(texts.count) }
        batchCtx.withLock { $0.append(context) }
        if texts.contains(where: failing.contains) {
            if delay != .zero { try await Task.sleep(for: delay) }
            throw FakeError.translation
        }
        var out: [String] = []
        for t in texts { out.append(try await translateOne(t)) }
        return out
    }

    private func translateOne(_ text: String) async throws -> String {
        if delay != .zero { try await Task.sleep(for: delay) }
        if failing.contains(text) { throw FakeError.translation }
        return "译:" + text
    }
}
