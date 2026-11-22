#if os(iOS)
import AVFoundation
import Foundation

/// The system wiring of `AudioCapture`: the audio session, the notifications that end the
/// stream, and releasing the engine. iOS only, like the class.
extension AudioCapture {
    /// Ends the stream on an interruption that began, on the loss of the input device, on an
    /// engine configuration change (the engine has stopped itself) and on a media services
    /// reset. The blocks run on the posting thread and take only the gate's lock.
    func observe(_ engine: AVAudioEngine, _ token: CaptureToken) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                               queue: nil) { [self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init) == .began { systemEnded(token) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                               queue: nil) { [self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable {
                    systemEnded(token)
                }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                               queue: nil) { [self] _ in systemEnded(token) },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                               object: nil, queue: nil) { [self] _ in systemEnded(token) },
        ]
    }

    /// Runs `body`, turning any error into `.engineStartFailed("<step>：<reason>")`.
    static func step<T>(_ step: String, _ body: () throws -> T) throws(AudioCaptureError) -> T {
        do {
            return try body()
        } catch {
            throw .engineStartFailed("\(step)：\(error.localizedDescription)")
        }
    }

    /// Configures and activates the shared audio session (see the class comment for why).
    static func activateSession() throws(AudioCaptureError) {
        let session = AVAudioSession.sharedInstance()
        try step("音频会话配置失败") {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredIOBufferDuration(0.1)
            try session.setActive(true)
        }
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops the engine, removes the tap and the observers and deactivates the session.
    static func release(_ running: Hardware) {
        running.engine.stop()
        running.engine.inputNode.removeTap(onBus: 0)
        running.observers.forEach { NotificationCenter.default.removeObserver($0) }
        deactivateSession()
    }
}
#endif
