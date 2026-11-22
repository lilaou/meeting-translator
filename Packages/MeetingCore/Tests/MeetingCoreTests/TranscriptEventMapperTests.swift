import Foundation
import Testing
@testable import MeetingCore

@Test func finalRangesAreClampedSoTheyNeverGoBackwards() {
    var mapper = TranscriptEventMapper()
    #expect(mapper.finalized(text: "A", start: 0, end: 2) == [.finalized(text: "A", range: 0...2)])
    #expect(mapper.finalized(text: "B", start: 1.5, end: 3) == [.finalized(text: "B", range: 2...3)])
    #expect(mapper.finalized(text: "C", start: 4, end: 3.5) == [.finalized(text: "C", range: 4...4)])
    #expect(mapper.finalized(text: "", start: .nan, end: .nan) == [.finalized(text: "", range: 4...4)])
    #expect(mapper.lastFinalEnd == 4)
}

@Test func hypothesisAfterTheFinalIsSentAgain() {
    var mapper = TranscriptEventMapper()
    #expect(mapper.volatile(text: "later words", start: 2) == [.volatile(text: "later words")])
    #expect(mapper.finalized(text: "Hello.", start: 0, end: 2)
        == [.finalized(text: "Hello.", range: 0...2), .volatile(text: "later words")])
}

@Test func hypothesisOverlappingTheFinalIsDropped() {
    var mapper = TranscriptEventMapper()
    _ = mapper.volatile(text: "Hello wor", start: 0)
    #expect(mapper.finalized(text: "Hello.", start: 0, end: 1) == [.finalized(text: "Hello.", range: 0...1)])
    // Dropped for good: a later final does not bring it back either.
    #expect(mapper.finalized(text: "World.", start: 1, end: 2) == [.finalized(text: "World.", range: 1...2)])
}

@Test func installedLocaleMatchesExactlyOrByLanguageWithoutRegion() {
    let installed = [Locale(identifier: "en-GB"), Locale(identifier: "en-US"), Locale(identifier: "zh-CN")]
    #expect(installedLocale(matching: Locale(identifier: "en_US"), in: installed)?.identifier(.bcp47) == "en-US")
    #expect(installedLocale(matching: Locale(identifier: "zh"), in: installed)?.identifier(.bcp47) == "zh-CN")
    #expect(installedLocale(matching: Locale(identifier: "en-AU"), in: installed) == nil)
    #expect(installedLocale(matching: Locale(identifier: "fr"), in: installed) == nil)
}

@Test func appleSpeechErrorsHaveReadableDescriptions() {
    struct Other: LocalizedError { var errorDescription: String? { "boom" } }
    #expect(AppleSpeechError.localeNotInstalled("en-US").localizedDescription.contains("en-US"))
    #expect(AppleSpeechError.wrapping(Other()) == .recognitionFailed("boom"))
    #expect(AppleSpeechError.wrapping(AppleSpeechError.noCompatibleAudioFormat) == .noCompatibleAudioFormat)
    #expect(AudioFileSourceError.unsupportedConversion.errorDescription?.isEmpty == false)
}
