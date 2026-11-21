import Testing
import AVFoundation
@testable import MeetingCore

@Test func fakeEngineEmitsEventsInOrder() async throws {
    let events: [ASREvent] = [.volatile(text: "hel"), .finalized(text: "Hello.", range: 0...1)]
    let engine = FakeASREngine(events: events)
    var got: [ASREvent] = []
    for try await e in engine.transcribe(AsyncStream { $0.finish() }, locale: Locale(identifier: "en-US")) { got.append(e) }
    #expect(got == events)
}

@Test func defaultBatchTranslatesEachInOrder() async throws {
    let t = FakeTranslator()
    let out = try await t.translateBatch(["a", "b"], from: .init(identifier: "en"), context: [])
    #expect(out == ["译:a", "译:b"])
}

/// Implements only the required methods, so translateBatch uses the protocol default.
private struct DefaultOnlyTranslator: Translator {
    func canTranslate(from source: Locale.Language) async -> Bool { true }
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String {
        "T:" + text
    }
}

@Test func protocolDefaultBatchTranslatesEachInOrder() async throws {
    let t = DefaultOnlyTranslator()
    let src = Locale.Language(identifier: "en")
    let three = try await t.translateBatch(["a", "b", "c"], from: src, context: [])
    #expect(three == ["T:a", "T:b", "T:c"])
    #expect(three.count == 3)
    let none = try await t.translateBatch([], from: src, context: [])
    #expect(none.isEmpty)
}
