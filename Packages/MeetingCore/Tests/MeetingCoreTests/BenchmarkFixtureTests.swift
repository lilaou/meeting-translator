import Foundation
import Testing
@testable import MeetingCore

private let deviceEnvironment = ["RUN_DEVICE_TESTS": "1"]
private let wavMissing = "Fixtures/benchmark-en.wav is not in the test bundle"
private let txtMissing = "Fixtures/benchmark-en.txt is not in the test bundle"

@Test func fixturesAreLoadedFromTheTestBundle() throws {
    let readme = try #require(BenchmarkFixture.url("README", "md"))
    #expect(try String(contentsOf: readme, encoding: .utf8).contains("benchmark-en.wav"))
}

// The tests below pass the presence of the recording and the keyword file explicitly, so they do
// not depend on whether the real benchmark fixtures have been added to the repository yet.

@Test func deviceTestSkipReasonNamesEverythingMissing() {
    #expect(BenchmarkFixture.missingRequirements(
        environment: [:], hasRecording: false, hasKeywords: false
    ) == ["RUN_DEVICE_TESTS is not set", wavMissing, txtMissing])
}

@Test func onlyTheMissingFixtureIsNamed() {
    #expect(BenchmarkFixture.missingRequirements(
        environment: deviceEnvironment, hasRecording: false, hasKeywords: true
    ) == [wavMissing])
    #expect(BenchmarkFixture.missingRequirements(
        environment: deviceEnvironment, hasRecording: true, hasKeywords: false
    ) == [txtMissing])
}

@Test func nothingIsMissingWhenTheEnvironmentAndBothFixturesArePresent() {
    #expect(BenchmarkFixture.missingRequirements(
        environment: deviceEnvironment, hasRecording: true, hasKeywords: true
    ).isEmpty)
}

@Test func theEnvironmentVariableIsRequiredEvenWithBothFixtures() {
    #expect(BenchmarkFixture.missingRequirements(
        environment: [:], hasRecording: true, hasKeywords: true
    ) == ["RUN_DEVICE_TESTS is not set"])
}
