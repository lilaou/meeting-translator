// Needs the iOS 26 / macOS 26 SDK (Swift 6.2+), like AppleSpeechEngine itself.
#if compiler(>=6.2)
import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

/// Runs only with `RUN_DEVICE_TESTS` set and both benchmark files in the test bundle
/// (see Fixtures/README.md); the skip message names whatever is missing.
@Test(.enabled(if: BenchmarkFixture.missingRequirements().isEmpty,
               Comment(rawValue: BenchmarkFixture.skipReason)))
func appleEngineTranscribesTheBenchmarkRecording() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else {
        Issue.record("AppleSpeechEngine needs iOS 26 / macOS 26")
        return
    }
    let recording = try #require(BenchmarkFixture.recording)
    let keywordFile = try #require(BenchmarkFixture.keywords)
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

/// Smoke test only (not verification of recognition): the engine conforms and
/// `supportedLocales()` returns, also without speech assets.
@Test func smokeAppleEngineConformsAndListsInstalledLocales() async {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let engine: any ASREngine = AppleSpeechEngine()
    let locales = await engine.supportedLocales()
    print("AppleSpeechEngine installed locales: \(locales.map { $0.identifier(.bcp47) })")
}

/// `qaa-ZZ` (private-use language, unknown region) can never be installed, so this checks on
/// every machine: `preferredFormat` fails, and the event stream finishes with the same
/// readable error instead of staying open.
@Test func appleEngineRejectsALocaleThatIsNotInstalled() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let engine = AppleSpeechEngine()
    let locale = Locale(identifier: "qaa-ZZ")
    let expected = AppleSpeechError.localeNotInstalled("qaa-ZZ")
    let installed = await engine.supportedLocales().map { $0.identifier(.bcp47) }
    #expect(!installed.contains("qaa-ZZ"))

    await #expect(throws: expected) { _ = try await engine.preferredFormat(for: locale) }
    let (audio, sink) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    sink.finish()
    await #expect(throws: expected) {
        for try await _ in engine.transcribe(audio, locale: locale) {}
    }
    #expect(expected.localizedDescription.contains("qaa-ZZ"))
}
#endif
