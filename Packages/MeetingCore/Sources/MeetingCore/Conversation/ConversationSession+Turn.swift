import AVFoundation
import Foundation

/// The streams, tasks and text of one turn. A turn is current while `session.turn === it`;
/// everything that arrives for another turn is ignored.
@MainActor final class ConversationTurn {
    let side: ConversationSide
    /// The speaking side tapped again before the recording had started.
    var endRequested = false
    var finals: [String] = []
    var volatile = ""
    var failure: (any Error)?
    var engineTimedOut = false
    var engineAudio: AsyncStream<AVAudioPCMBuffer>.Continuation?
    var forwarder: Task<Void, Never>?
    var engineTask: Task<Void, Never>?
    var pauseTimer: Task<Void, Never>?
    var silenceTimer: Task<Void, Never>?
    var maximumTimer: Task<Void, Never>?
    var wrapUp: Task<Void, Never>?

    init(side: ConversationSide) { self.side = side }

    func cancelTimers() {
        for timer in [pauseTimer, silenceTimer, maximumTimer] { timer?.cancel() }
    }
}

extension ConversationSession {
    func begin(_ side: ConversationSide) async {
        let turn = ConversationTurn(side: side)
        self.turn = turn
        phase = .starting(side)
        liveText = ""
        notice = nil
        saveFailed = false
        await queueAudio { await self.record(turn) }.value
    }

    /// Runs `operation` after every earlier start and stop of the audio has completed, so
    /// there is never a second recording and a late stop cannot end a newer one.
    @discardableResult
    private func queueAudio(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = audioTail
        let task = Task {
            await previous?.value
            await operation()
        }
        audioTail = task
        return task
    }

    private func record(_ turn: ConversationTurn) async {
        guard self.turn === turn else { return }
        do {
            let wiring = try await SessionCoordinator.connect(
                engine: engine, audio: audio, locale: turn.side.speechLocale,
                isWanted: { self.turn === turn })
            // Dropped meanwhile: the stop that `discard` queued turns the microphone off.
            guard self.turn === turn else { return wiring.engineAudio.finish() }
            listen(to: wiring, turn)
        } catch {
            guard self.turn === turn else { return }
            notice = .failed(UserMessages.hint(for: error))
            endTurn()
        }
    }

    private func listen(to wiring: PipelineWiring, _ turn: ConversationTurn) {
        turn.engineAudio = wiring.engineAudio
        turn.forwarder = wiring.forwarder
        phase = .listening(turn.side)
        let events = wiring.events
        turn.engineTask = Task { [weak self] in
            do {
                for try await event in events { self?.handle(event, turn) }
            } catch {
                // Cancelled only by a drain timeout or a drop; neither is an engine failure.
                if !Task.isCancelled { turn.failure = error }
            }
            self?.finish(turn)
        }
        Task { [weak self] in
            await wiring.forwarder.value      // the audio ended, e.g. an incoming call
            self?.finish(turn)
        }
        turn.silenceTimer = timer(timing.silence, turn)
        turn.maximumTimer = timer(timing.maximum, turn)
        if turn.endRequested { finish(turn) }
    }

    private func handle(_ event: ASREvent, _ turn: ConversationTurn) {
        guard self.turn === turn else { return }
        switch event {
        case .volatile(let text):
            turn.volatile = text
        case .finalized(let text, _):
            turn.finals.append(text)
            turn.volatile = ""
        }
        let text = ConversationText.join(turn.finals + [turn.volatile])
        guard text != liveText else { return }
        liveText = text
        // Reached only once there is (or was) text: from the first text on, the pause limit,
        // restarted by every change, replaces the silence limit.
        guard phase == .listening(turn.side) else { return }
        turn.silenceTimer?.cancel()
        turn.pauseTimer?.cancel()
        turn.pauseTimer = timer(timing.pause, turn)
    }

    private func timer(_ duration: Duration, _ turn: ConversationTurn) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.finish(turn)
        }
    }

    func finish(_ turn: ConversationTurn) {
        guard self.turn === turn, phase == .listening(turn.side) else { return }
        phase = .finishing(turn.side)
        turn.cancelTimers()
        turn.wrapUp = Task { await self.wrapUp(turn) }
    }

    private func wrapUp(_ turn: ConversationTurn) async {
        await queueAudio { [audio] in await audio.stop() }.value
        if let forwarder = turn.forwarder {
            await SessionCoordinator.drainAudio(forwarder, engineAudio: turn.engineAudio,
                                                timeout: SessionCoordinator.defaultAudioDrainTimeout)
        }
        await drainEngine(turn)
        guard self.turn === turn else { return }
        let original = liveText
        guard !original.isEmpty else {
            let timeout: Notice = turn.engineTimedOut ? .failed(UserMessages.recognitionTimedOut) : .notHeard
            notice = turn.failure.map { .failed(UserMessages.hint(for: $0)) } ?? timeout
            return endTurn()
        }
        while isBackground {
            await waitForForeground()
            guard self.turn === turn else { return }
        }
        let translation = await translate(original, from: turn.side)
        guard self.turn === turn else { return }
        add(turn.side, original, translation)
        endTurn()
    }

    /// Shows the turn and saves it; a failed save leaves the conversation as it is.
    private func add(_ side: ConversationSide, _ original: String, _ translation: String?) {
        utterances.append(ConversationUtterance(id: utterances.count, speaker: side,
                                                original: original, translation: translation))
        do {
            try saver?.save(speaker: side, original: original, translation: translation)
        } catch {
            saveFailed = true
        }
    }

    /// As in the meeting: past the bound the engine is cancelled and what was heard is kept.
    private func drainEngine(_ turn: ConversationTurn) async {
        guard let engineTask = turn.engineTask else { return }
        let ended = await withTimeout(engineDrainTimeout) {
            await engineTask.value
            return true
        } ?? false
        guard !ended else { return }
        turn.engineTimedOut = true
        engineTask.cancel()
        await engineTask.value
    }

    private func waitForForeground() async {
        let (stream, signal) = AsyncStream<Void>.makeStream()
        foregroundSignal = signal
        for await _ in stream {}
    }

    /// nil when the translation fails or does not return in time.
    private func translate(_ text: String, from side: ConversationSide) async -> String? {
        let translator = translator(side)
        let source = side.translationLanguage
        let result = await withTimeout(translationTimeout) {
            try? await translator.translate(text, from: source, context: [])
        }
        return result.flatMap { $0 }
    }

    /// Drops the turn in progress: nothing of it appears any more, and the audio is stopped.
    func discard() {
        guard let turn else { return }
        turn.cancelTimers()
        turn.engineTask?.cancel()
        turn.wrapUp?.cancel()
        turn.engineAudio?.finish()
        foregroundSignal?.finish()
        foregroundSignal = nil
        endTurn()
        queueAudio { [audio] in await audio.stop() }
    }

    private func endTurn() {
        turn = nil
        phase = .idle
        liveText = ""
    }
}
