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
