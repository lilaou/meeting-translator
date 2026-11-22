import Foundation
import Testing
@testable import MeetingCore

@Test func fixturesAreLoadedFromTheTestBundle() throws {
    let readme = try #require(BenchmarkFixture.url("README", "md"))
    #expect(try String(contentsOf: readme, encoding: .utf8).contains("benchmark-en.wav"))
}

@Test func deviceTestSkipReasonNamesEverythingMissing() {
    // The recording is not in the repository, so both files are reported missing.
    #expect(BenchmarkFixture.missingRequirements(environment: [:]) == [
        "RUN_DEVICE_TESTS is not set",
        "Fixtures/benchmark-en.wav is not in the test bundle",
        "Fixtures/benchmark-en.txt is not in the test bundle",
    ])
    #expect(BenchmarkFixture.missingRequirements(environment: ["RUN_DEVICE_TESTS": "1"]).count == 2)
}
