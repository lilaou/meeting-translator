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
        await drainEngine()              // every remaining final is handled before the flush
        if let sentence = assembler.flush() { submit(sentence) }
        volatileText = ""
        await enqueueTail?.value
        await drainTranslations()        // every outcome that arrived is in the store
        await laggingTask?.value
        isTranslationLagging = false
        if let meetingID {
            do { try store.endMeeting(meetingID, at: Date()) } catch { endMeetingError = error }
        }
        clearPipeline()
        state = finalState()
    }

    /// Waits at most `engineDrainTimeout` for the recognition stream to end. On timeout the
    /// engine task is cancelled: its `for try await` ends at once (stream iteration responds to
    /// cancellation) and the stream's `onTermination` lets the engine cancel its analyzer, so
    /// awaiting the task afterwards is bounded. Finals not delivered by then are reported lost.
    private func drainEngine() async {
        guard let engineTask else { return }
        let ended = await withTimeout(config.engineDrainTimeout) {
            await engineTask.value
            return true
        } ?? false
        guard !ended else { return }
        engineDrainTimedOut = true
        engineTask.cancel()
        await engineTask.value
    }

    /// Waits at most `translationDrainTimeout` for the queue to drain and every outcome to be
    /// applied. On timeout the queue is abandoned: the request in flight (which may ignore
    /// cancellation) is never awaited and its late result is discarded by the queue; the
    /// sentences without an outcome stay stored as pending, with their source text.
    private func drainTranslations() async {
        guard let queue else { return }
        let outcomeTask = self.outcomeTask
        let drained = await withTimeout(config.translationDrainTimeout) {
            await queue.finish()
            await outcomeTask?.value
            return true
        } ?? false
        guard !drained else { return }
        untranslatedSentences = await queue.abandon().count
        // abandon() finished `outcomes`: the outcome task applies what had already arrived,
        // then ends. It is the only writer of translations, so once it has ended nothing can
        // write to this meeting's segments any more (`endMeeting` runs after this).
        await outcomeTask?.value
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
