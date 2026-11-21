import AVFoundation
import Foundation

extension SessionCoordinator {
    /// How long wrap-up waits, after `audio.stop()`, for the source to finish its stream
    /// before it cuts the engine's audio off itself (a well-behaved source finishes at once).
    static let defaultAudioDrainTimeout: Duration = .seconds(1)

    func audioDidEnd() {
        if state == .listening { beginWrapUp() }
    }

    /// An error is kept even when wrap-up is already running: finals the engine never
    /// delivered are lost, so the meeting must end in `.failed`.
    func engineDidEnd(error: (any Error)?) {
        if let error { engineError = error }
        if state == .listening { beginWrapUp() }
    }

    /// Starts the single wrap-up (or returns the one already running).
    @discardableResult
    func beginWrapUp() -> Task<Void, Never> {
        if let wrapUpTask { return wrapUpTask }
        state = .finishing
        let task = Task { await self.wrapUp() }
        wrapUpTask = task
        return task
    }

    private func wrapUp() async {
        pauseTask?.cancel()
        await pauseTask?.value
        await audio.stop()
        if let forwardTask {             // the audio tail reaches the engine, in order
            await Self.drainAudio(forwardTask, engineAudio: engineAudio, timeout: audioDrainTimeout)
        }
        await audioEndTask?.value
        await engineTask?.value          // every remaining final is handled before the flush
        if let sentence = assembler.flush() { submit(sentence) }
        volatileText = ""
        await enqueueTail?.value
        await queue?.finish()
        await outcomeTask?.value         // every outcome is in the store
        await laggingTask?.value
        isTranslationLagging = false
        if let meetingID {
            do { try store.endMeeting(meetingID, at: Date()) } catch { endMeetingError = error }
        }
        clearPipeline()
        state = finalState()
    }

    /// Waits for the forwarder, which copies every buffer the source already yielded and then
    /// finishes the engine's audio itself. Returns as soon as it ends. Only if the source has
    /// not finished its stream within `timeout` is the engine's audio cut off here (fallback).
    nonisolated static func drainAudio(
        _ forwarder: Task<Void, Never>,
        engineAudio: AsyncStream<AVAudioPCMBuffer>.Continuation?, timeout: Duration
    ) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await forwarder.value; return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            if await group.next() == false {
                engineAudio?.finish()
                forwarder.cancel()       // ends its loop, so the first child returns too
            }
            group.cancelAll()            // a forwarder that won stops the timeout at once
        }
    }

    private func clearPipeline() {
        queue = nil
        engineAudio = nil
        forwardTask = nil
        audioEndTask = nil
        engineTask = nil
        outcomeTask = nil
        laggingTask = nil
        pauseTask = nil
        enqueueTail = nil
        wrapUpTask = nil
    }
}
