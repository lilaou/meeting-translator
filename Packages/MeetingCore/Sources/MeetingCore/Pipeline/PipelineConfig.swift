import Foundation

public struct PipelineConfig: Sendable {
    // Provisional defaults: to be recalibrated from Phase 0 device measurements
    // (final segment length, translation latency) once docs/phase0-results.md exists.
    public var maxSentenceCharacters = 200
    public var pauseTimeout: Duration = .seconds(2)
    public var backlogThreshold = 5
    public var contextSize = 3
    /// At the end of a meeting, how long to wait for the recognition stream to end after its
    /// audio ended. On timeout the engine is cancelled and the meeting still ends, as `.failed`.
    /// Provisional default, to be tuned with device data.
    public var engineDrainTimeout: Duration = .seconds(10)
    /// At the end of a meeting, how long to wait for the translation queue to drain. The bound
    /// covers the WHOLE remaining backlog, not one stalled call. On timeout the remaining
    /// sentences stay `pendingTranslation` with their source text saved (Phase 1 has no retry,
    /// so their translation is not made later) and the meeting still ends, as `.failed`.
    /// Provisional default, to be tuned with device data; whether to bound "no progress"
    /// instead is an open design decision (docs/superpowers/notes/2026-11-21-engine-contracts.md).
    public var translationDrainTimeout: Duration = .seconds(30)
    public init() {}
}
