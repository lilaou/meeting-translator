// Needs the iOS 26 / macOS 26 SDK (Swift 6.2+), like AppleSpeechEngine itself.
#if compiler(>=6.2)
import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

/// `Tests/Fixtures/benchmark-en.wav`: a public English recording whose license allows
/// redistribution. Its three pre-picked keywords go one per line in `benchmark-en.txt`.
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
private let recording = fixtures.appendingPathComponent("benchmark-en.wav")
private let keywordFile = fixtures.appendingPathComponent("benchmark-en.txt")

private let deviceRunRequested = ProcessInfo.processInfo.environment["RUN_DEVICE_TESTS"] != nil
    && FileManager.default.fileExists(atPath: recording.path)

@Test(.enabled(if: deviceRunRequested, "needs RUN_DEVICE_TESTS and Tests/Fixtures/benchmark-en.wav"))
func appleEngineTranscribesTheBenchmarkRecording() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else {
        Issue.record("AppleSpeechEngine needs iOS 26 / macOS 26")
        return
    }
    let keywords = try String(contentsOf: keywordFile, encoding: .utf8)
        .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }
    try #require(keywords.count == 3, "benchmark-en.txt must list three keywords")

    let engine = AppleSpeechEngine()
    let locale = Locale(identifier: "en-US")
    let format = try await engine.preferredFormat(for: locale)
    let audio = try audioBuffers(fromFile: recording, format: format)

    var volatileCount = 0
    var finals: [(text: String, range: ClosedRange<TimeInterval>)] = []
    for try await event in engine.transcribe(audio, locale: locale) {
        switch event {
        case .volatile: volatileCount += 1
        case .finalized(let text, let range): finals.append((text, range))
        }
    }

    #expect(volatileCount > 0)
    #expect(!finals.isEmpty)
    #expect(zip(finals, finals.dropFirst()).allSatisfy {
        $0.range.lowerBound <= $1.range.lowerBound && $0.range.upperBound <= $1.range.upperBound
    })
    let transcript = finals.map(\.text).joined(separator: " ").lowercased()
    for keyword in keywords { #expect(transcript.contains(keyword), "missing keyword \(keyword)") }
}

/// Safe without speech assets: conformance, and `supportedLocales()` returns.
@Test func appleEngineConformsAndListsInstalledLocales() async {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let engine: any ASREngine = AppleSpeechEngine()
    let locales = await engine.supportedLocales()
    print("AppleSpeechEngine installed locales: \(locales.map { $0.identifier(.bcp47) })")
}

/// Safe without speech assets: a locale that is not installed fails `preferredFormat` and
/// finishes the event stream with a readable error instead of leaving it open.
@Test func appleEngineRejectsALocaleThatIsNotInstalled() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let engine = AppleSpeechEngine()
    let locale = Locale(identifier: "en-US")
    let installed = await engine.supportedLocales().map { $0.identifier(.bcp47) }
    guard !installed.contains("en-US") else { return }   // assets present: nothing to check
    let expected = AppleSpeechError.localeNotInstalled("en-US")

    await #expect(throws: expected) { _ = try await engine.preferredFormat(for: locale) }
    let (audio, sink) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    sink.finish()
    await #expect(throws: expected) {
        for try await _ in engine.transcribe(audio, locale: locale) {}
    }
    #expect(expected.localizedDescription.contains("en-US"))
}
#endif
