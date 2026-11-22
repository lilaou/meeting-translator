#if os(iOS)
import AVFoundation
import Foundation
import Synchronization

/// 麦克风采集：iPhone 上真实的 `AudioSource`。
///
/// `start(format:)` asks for the microphone permission (`AVAudioApplication`), configures and
/// activates the audio session, installs a tap on the input node of a new `AVAudioEngine` and
/// yields every tap buffer converted into fresh buffers of exactly `format`. One stream at a
/// time; a capture can start again after its stream ended. Phase 1 does not resume after an
/// interruption: the stream just ends and the coordinator wraps the meeting up.
///
/// How the `AudioSource` contract is met (the logic is in two ungated, unit-tested helpers):
/// - fresh buffers: `AudioBufferConverter` allocates every output buffer itself and never
///   returns the tap's buffer, even for identical formats;
/// - the stream ends on `stop()`, on an interruption that began, on the loss of the input
///   route, on an engine configuration change (the engine stopped itself) and on a media
///   services reset; `CaptureStreamGate` ends it exactly once and yields nothing afterwards;
/// - `stop()` is idempotent and safe before `start` and after the stream ended on its own; it
///   stops the engine first, then yields the converter's flushed tail, then ends the stream;
/// - a second `start` while starting or running throws `.engineStartFailed("already running")`;
/// - output format: the converter is built for exactly `format`.
///
/// Errors: permission denied → `.permissionDenied`; any session, engine or converter failure
/// → `.engineStartFailed(<readable step and reason>)`, after undoing what was set up
/// (tap, engine, observers) and deactivating the session again.
///
/// Audio session (spec §10): category `.record` — Phase 1 only records, nothing is played;
/// mode `.measurement` — the least system processing of the input (no voice-chat echo
/// cancellation or gain tuned for a near-field talker), which is what Apple's speech
/// recognition samples use and what a recognizer listening to people across a meeting table
/// should get; no options — in particular no `.allowBluetooth`, so the built-in microphone
/// stays the input even with AirPods connected (their hands-free microphone is narrowband
/// and near-field); a preferred IO buffer of 0.1 s — captions do not need lower latency and
/// fewer wake-ups save power. Activated on `start`, deactivated with
/// `.notifyOthersOnDeactivation` when the stream ends. Recording in the background needs
/// `UIBackgroundModes: audio` and `NSMicrophoneUsageDescription` (Task 11).
///
/// UNVERIFIED without a device (nothing here touches a microphone in tests): the permission
/// prompt and its denial; on which thread, how often and with what frame counts the tap
/// fires; whether interruption, route-change, configuration-change and media-reset
/// notifications arrive as assumed (and in which order); the behaviour with Bluetooth,
/// AirPods and wired routes; whether `.measurement` actually gives the best recognition of
/// far-field speech (`.default` adds automatic gain); the actual IO buffer the system grants;
/// battery and thermal cost over a two-hour meeting; recording in the background.
public final class AudioCapture: AudioSource {
    /// The running engine and the notification observers of one stream.
    struct Hardware {
        let token: CaptureToken
        let engine: AVAudioEngine
        let observers: [any NSObjectProtocol]
    }

    private let gate = CaptureStreamGate<AVAudioPCMBuffer, AudioBufferConverter>()
    /// Locking order: `hardware`, then the gate's lock — never the other way round. Callbacks
    /// (tap, notifications, stream termination) take only the gate's lock and leave the
    /// teardown to a task, so nothing waits for `hardware` while holding the gate's lock.
    private let hardware = Mutex<Hardware?>(nil)

    public init() {}

    public func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let token: CaptureToken
        do {
            token = try gate.reserve()
        } catch {
            throw AudioCaptureError.engineStartFailed("already running")
        }
        // A stream that ended on its own frees the gate at once, but its teardown task may not
        // have run yet; release that engine now, before the new session is activated.
        hardware.withLock { current in
            if let stale = current { Self.release(stale) }
            current = nil
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            gate.finish(token)
            throw AudioCaptureError.permissionDenied
        }
        do {
            try Self.activateSession()
        } catch {
            gate.finish(token)
            Self.deactivateSession()
            throw error
        }
        // The engine is made after the session is configured, so that configuring it is not
        // a configuration change of this engine. Observing before the engine starts: an event
        // during startup ends the reservation, and the start then fails instead of returning
        // a dead stream.
        let engine = AVAudioEngine()
        let running = Hardware(token: token, engine: engine, observers: observe(engine, token))
        let stream: AsyncStream<AVAudioPCMBuffer>
        do {
            stream = try launch(engine, token: token, format: format)
        } catch {
            gate.finish(token)
            Self.release(running)
            throw error
        }
        let kept = hardware.withLock { current in
            // `running` is local and never used again after this line, so the lock's state
            // takes it over (the explicit hand-off is needed because Swift 6.1 cannot see
            // that through the capture, as in `SpeechFileWriter.append`).
            nonisolated(unsafe) let owned = running
            return Self.keep(owned, while: gate, in: &current)
        }
        guard kept else { throw AudioCaptureError.engineStartFailed("录音在启动时被停止或中断") }
        return stream
    }

    public func stop() async {
        tearDown(nil)
    }

    /// Sets up the converter and the tap, opens the stream and starts the engine.
    private func launch(_ engine: AVAudioEngine, token: CaptureToken,
                        format: AVAudioFormat) throws(AudioCaptureError) -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw .engineStartFailed("没有可用的麦克风输入")
        }
        let converter = try Self.step("音频格式转换不可用") {
            try AudioBufferConverter(from: hardwareFormat, to: format)
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat) { [self] buffer, _ in
            if case .failed = gate.yield(token, { try $0.convert(buffer) }) {
                Task { self.tearDown(token) }
            }
        }
        // The converter is new and nothing else holds it. It only keeps the two formats,
        // which AVAudioFormat never mutates after creation, so the gate may own it.
        nonisolated(unsafe) let owned = converter
        guard let stream = gate.open(token, source: owned, onTermination: { [self] in
            // Also runs when the consumer goes away; may run on any thread, possibly inside
            // a teardown, so it must not take the `hardware` lock itself.
            Task { self.tearDown(token) }
        }) else {
            throw .engineStartFailed("录音已被停止")
        }
        try Self.step("音频引擎启动失败") {
            engine.prepare()
            try engine.start()
        }
        return stream
    }

    /// Ends the stream at a system event: at once and exactly once (nothing more is yielded),
    /// then tears the hardware down off the notification thread.
    func systemEnded(_ token: CaptureToken) {
        gate.finish(token) { converter in (try? converter.flush()) ?? [] }
        Task { self.tearDown(token) }
    }

    /// Stops the engine of `token` (or of the current stream when nil), yields the converter's
    /// tail, ends the stream, removes the observers and deactivates the session. Idempotent;
    /// with no running hardware it only cancels a reservation that is still starting.
    private func tearDown(_ token: CaptureToken?) {
        hardware.withLock { current in
            guard let running = current, token == nil || token == running.token else {
                gate.finish(token)
                return
            }
            current = nil
            running.engine.stop()          // first: the flush below is then the real tail
            gate.finish(running.token) { converter in (try? converter.flush()) ?? [] }
            Self.release(running)
        }
    }

    /// Takes over `running` if its stream is still current (a `stop()` or a system event
    /// during startup ended it), otherwise releases it. Call with the `hardware` lock held.
    private static func keep(_ running: sending Hardware, while gate: CaptureStreamGate<AVAudioPCMBuffer, AudioBufferConverter>,
                             in current: inout Hardware?) -> Bool {
        guard gate.isCurrent(running.token) else {
            release(running)
            return false
        }
        current = running
        return true
    }
}
#endif
