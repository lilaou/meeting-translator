import Foundation

/// The benchmark recording for the Apple engine device test, loaded from the test bundle
/// (`Fixtures/` is a test resource, so this works on a device too; see Fixtures/README.md).
enum BenchmarkFixture {
    static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    }

    static var recording: URL? { url("benchmark-en", "wav") }
    /// Three keywords spoken in the recording, one per line.
    static var keywords: URL? { url("benchmark-en", "txt") }

    /// What the device test still needs here; empty when it can run.
    static func missingRequirements(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var missing: [String] = []
        if environment["RUN_DEVICE_TESTS"] == nil { missing.append("RUN_DEVICE_TESTS is not set") }
        if recording == nil { missing.append("Fixtures/benchmark-en.wav is not in the test bundle") }
        if keywords == nil { missing.append("Fixtures/benchmark-en.txt is not in the test bundle") }
        return missing
    }

    /// The device test's skip reason, naming everything that is missing.
    static var skipReason: String {
        "skipped: " + missingRequirements().joined(separator: "; ")
    }
}
