import Foundation

public struct TranslationOutcome: Sendable {
    public let segmentID: UUID
    /// nil 表示失败（原文保留，由调用方标记失败）。
    public let translation: String?

    public init(segmentID: UUID, translation: String?) {
        self.segmentID = segmentID
        self.translation = translation
    }
}

/// Serial, batching translation queue.
///
/// - At most one translation request is in flight. When idle, `enqueue` snapshots the
///   pending sentences and starts a request before returning; sentences enqueued while a
///   request runs accumulate and are all sent as the next batch when it completes.
/// - `context` of a request = sources of the last `contextSize` sentences sent in earlier
///   requests, oldest first.
/// - If `translateBatch` throws (or returns the wrong count), each sentence of that batch is
///   retried with `translate` using the same context; a sentence that still fails yields
///   `translation == nil`. No sentence is ever dropped and `outcomes` is in enqueue order.
/// - `lagging` emits `true` when the pending count (queued + in flight) rises to
///   `backlogThreshold`, and `false` when it falls back below it.
public actor TranslationQueue {
    private struct Item: Sendable {
        let id: UUID
        let text: String
    }

    public nonisolated let outcomes: AsyncStream<TranslationOutcome>
    public nonisolated let lagging: AsyncStream<Bool>

    private let translator: any Translator
    private let source: Locale.Language
    private let config: PipelineConfig
    private let outcomeSink: AsyncStream<TranslationOutcome>.Continuation
    private let laggingSink: AsyncStream<Bool>.Continuation

    private var queued: [Item] = []
    private var inFlight = false
    private var pending = 0
    private var isLagging = false
    private var sentSources: [String] = []
    private var isFinished = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(translator: any Translator, source: Locale.Language, config: PipelineConfig) {
        self.translator = translator
        self.source = source
        self.config = config
        (outcomes, outcomeSink) = AsyncStream.makeStream()
        (lagging, laggingSink) = AsyncStream.makeStream()
    }

    /// Calling this after `finish()` is a caller error; the sentence is ignored.
    public func enqueue(segmentID: UUID, text: String) {
        guard !isFinished else { return }
        queued.append(Item(id: segmentID, text: text))
        pending += 1
        updateLagging()
        if !inFlight { startNextBatch() }
    }

    /// 队列清空且在途请求完成后返回，并结束两个流
    public func finish() async {
        isFinished = true
        if inFlight {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        outcomeSink.finish()
        laggingSink.finish()
    }

    private func startNextBatch() {
        guard !queued.isEmpty else {
            inFlight = false
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
            return
        }
        inFlight = true
        let batch = queued
        queued = []
        let context = Array(sentSources.suffix(max(config.contextSize, 0)))
        sentSources = Array((sentSources + batch.map(\.text)).suffix(max(config.contextSize, 0)))
        let translator = translator, source = source
        // The Task inherits this actor's isolation (it captures self); the translator call
        // itself is nonisolated, so the actor stays free for enqueues while it runs.
        Task {
            let results = await Self.translate(batch.map(\.text), translator: translator,
                                               source: source, context: context)
            self.complete(batch, results: results)
        }
    }

    private func complete(_ batch: [Item], results: [String?]) {
        for (item, translation) in zip(batch, results) {
            outcomeSink.yield(TranslationOutcome(segmentID: item.id, translation: translation))
        }
        pending -= batch.count
        updateLagging()
        startNextBatch()
    }

    private func updateLagging() {
        let shouldLag = pending >= config.backlogThreshold
        guard shouldLag != isLagging else { return }
        isLagging = shouldLag
        laggingSink.yield(shouldLag)
    }

    /// Returns one entry per text, same order; nil marks a sentence that failed.
    private nonisolated static func translate(
        _ texts: [String], translator: any Translator,
        source: Locale.Language, context: [String]
    ) async -> [String?] {
        if let batch = try? await translator.translateBatch(texts, from: source, context: context),
           batch.count == texts.count {
            return batch
        }
        var out: [String?] = []
        for text in texts {
            out.append(try? await translator.translate(text, from: source, context: context))
        }
        return out
    }
}
