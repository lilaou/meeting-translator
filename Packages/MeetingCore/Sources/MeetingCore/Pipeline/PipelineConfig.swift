import Foundation

public struct PipelineConfig: Sendable {
    // Provisional defaults: to be recalibrated from Phase 0 device measurements
    // (final segment length, translation latency) once docs/phase0-results.md exists.
    public var maxSentenceCharacters = 200
    public var pauseTimeout: Duration = .seconds(2)
    public var backlogThreshold = 5
    public var contextSize = 3
    public init() {}
}
