import AVFoundation
import Foundation

/// Audio and engine streams of one meeting. The audio buffers (not Sendable) stay inside the
/// forwarding task; the main actor only sees Sendable handles.
struct PipelineWiring: Sendable {
    let events: AsyncThrowingStream<ASREvent, Error>
    let engineAudio: AsyncStream<AVAudioPCMBuffer>.Continuation
    /// Copies audio to the engine; finishes `engineAudio` and completes when the audio ends.
    let forwarder: Task<Void, Never>
}

extension SessionCoordinator {
    /// Starts the audio and hands the engine our own audio stream, so we learn when the audio ends.
    nonisolated static func connect(engine: any ASREngine, audio: any AudioSource,
                                    locale: Locale) async throws -> PipelineWiring {
        let format = try await engine.preferredFormat(for: locale)
        let source = try await audio.start(format: format)
        let (engineAudio, sink) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let forwarder = Task {
            for await buffer in source {
                // AsyncStream's iterator does not mark its element `sending`, but each buffer
                // was yielded into `source` as `sending` and this task never touches it again,
                // so handing it on is a plain ownership transfer.
                nonisolated(unsafe) let handoff = buffer
                sink.yield(handoff)
            }
            sink.finish()
        }
        let events = engine.transcribe(engineAudio, locale: locale)
        return PipelineWiring(events: events, engineAudio: sink, forwarder: forwarder)
    }

    /// Wires engine → assembler → store/queue for the meeting in `meetingID`.
    /// Runs synchronously on the main actor, so no task here runs before `state` is `.listening`.
    func launchPipeline(_ wiring: PipelineWiring, locale: Locale) {
        assembler = SentenceAssembler(maxCharacters: config.maxSentenceCharacters)
        let queue = TranslationQueue(translator: translator, source: locale.language, config: config)
        self.queue = queue
        enqueueTail = nil
        engineAudio = wiring.engineAudio
        forwardTask = wiring.forwarder
        audioEndTask = Task { [weak self] in
            await wiring.forwarder.value
            self?.audioDidEnd()
        }

        let events = wiring.events
        engineTask = Task { [weak self] in
            var failure: (any Error)?
            do {
                for try await event in events { self?.handle(event) }
            } catch {
                failure = error
            }
            self?.engineDidEnd(error: failure)
        }

        outcomeTask = Task { [weak self] in
            for await outcome in queue.outcomes { self?.apply(outcome) }
        }
        laggingTask = Task { [weak self] in
            for await lagging in queue.lagging { self?.isTranslationLagging = lagging }
        }
    }

    func handle(_ event: ASREvent) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .finalized(let text, let range):
            volatileText = ""
            for sentence in assembler.ingest(text: text, range: range) { submit(sentence) }
        }
        restartPauseTimer()
    }

    /// Writes the sentence to disk at once, then queues it for translation.
    func submit(_ sentence: Sentence) {
        guard let meetingID, let queue,
              let segmentID = try? store.append(sentence, to: meetingID) else { return }
        let previous = enqueueTail
        enqueueTail = Task {
            await previous?.value
            await queue.enqueue(segmentID: segmentID, text: sentence.text)
        }
    }

    func apply(_ outcome: TranslationOutcome) {
        if let translation = outcome.translation {
            try? store.setTranslation(translation, for: outcome.segmentID)
        } else {
            try? store.markTranslationFailed(outcome.segmentID)
        }
    }

    // MARK: - Pause timer

    /// Any recognition event resets the timer; it only runs while text is pending.
    private func restartPauseTimer() {
        pauseTask?.cancel()
        pauseTask = nil
        guard state == .listening, assembler.hasPending else { return }
        let timeout = config.pauseTimeout
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.pauseDidElapse()
        }
    }

    private func pauseDidElapse() {
        guard state == .listening, let sentence = assembler.flush() else { return }
        submit(sentence)
    }

    // MARK: - Wrap-up

    private func audioDidEnd() {
        if state == .listening { beginWrapUp(error: nil) }
    }

    private func engineDidEnd(error: (any Error)?) {
        if state == .listening { beginWrapUp(error: error) }
    }

    /// Starts the single wrap-up (or returns the one already running).
    @discardableResult
    func beginWrapUp(error: (any Error)?) -> Task<Void, Never> {
        if let wrapUpTask { return wrapUpTask }
        state = .finishing
        let task = Task { await self.wrapUp(error: error) }
        wrapUpTask = task
        return task
    }

    private func wrapUp(error: (any Error)?) async {
        pauseTask?.cancel()
        await pauseTask?.value
        await audio.stop()
        // Defensive: the engine must see the audio end even if the source never finishes.
        engineAudio?.finish()
        forwardTask?.cancel()
        await audioEndTask?.value
        await engineTask?.value          // every remaining final is handled before the flush
        if let sentence = assembler.flush() { submit(sentence) }
        volatileText = ""
        await enqueueTail?.value
        await queue?.finish()
        await outcomeTask?.value         // every outcome is in the store
        await laggingTask?.value
        isTranslationLagging = false
        if let meetingID { try? store.endMeeting(meetingID, at: Date()) }
        clearPipeline()
        state = error.map { .failed(Self.hint(for: $0)) } ?? .idle
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
