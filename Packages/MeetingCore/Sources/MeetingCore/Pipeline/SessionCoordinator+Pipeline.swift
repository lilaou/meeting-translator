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
    /// If `isWanted` is false once the format is known, throws `CancellationError` without
    /// starting the audio.
    nonisolated static func connect(
        engine: any ASREngine, audio: any AudioSource, locale: Locale,
        isWanted: @MainActor () -> Bool = { true }
    ) async throws -> PipelineWiring {
        let format = try await engine.preferredFormat(for: locale)
        guard await isWanted() else { throw CancellationError() }
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
        unsavedSentences = 0
        unsavedResults = 0
        lastWriteError = nil
        endMeetingError = nil
        engineError = nil
        engineDrainTimedOut = false
        untranslatedSentences = 0
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
                // Cancelled only by a wrap-up whose engine drain timed out; that is reported
                // as such, so an error caused by the cancellation is not reported again.
                if !Task.isCancelled { failure = error }
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

    /// Writes the sentence to disk at once (one retry), then queues it for translation.
    /// A sentence that still cannot be saved is counted and reported at wrap-up (R14).
    func submit(_ sentence: Sentence) {
        guard let meetingID, let queue else { return }
        let segmentID: UUID
        do {
            segmentID = try (try? store.append(sentence, to: meetingID))
                ?? store.append(sentence, to: meetingID)
        } catch {
            unsavedSentences += 1
            lastWriteError = error
            return
        }
        let previous = enqueueTail
        enqueueTail = Task {
            await previous?.value
            await queue.enqueue(segmentID: segmentID, text: sentence.text)
        }
    }

    func apply(_ outcome: TranslationOutcome) {
        do {
            if let translation = outcome.translation {
                try store.setTranslation(translation, for: outcome.segmentID)
            } else {
                try store.markTranslationFailed(outcome.segmentID)
            }
        } catch {
            unsavedResults += 1
            lastWriteError = error
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
}
