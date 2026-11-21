# 引擎与音频来源的约定（Task 7 / 8 / 9）

这些约定来自对核心包 `Packages/MeetingCore` 的整支分支复审。`SessionCoordinator`、`TranslationQueue` 和 `SentenceAssembler` 依赖它们，接下来实现真实引擎的人必须遵守。

注意：协调器一侧的识别流收尾和翻译收尾目前还没有时间上限，仍是未完成事项，见文末“未完成事项”。

## ASREngine（Task 7）

1. 输入音频流结束后，先送出剩下的所有定稿，再在有限时间内结束事件流。绝不能让事件流一直开着。
2. 消费方取消时（`onTermination`），取消并释放 analyzer。
3. `finalized` 事件之后不会再被修改。它的 `range` 以输入流开始为零点、单位是秒，而且不会倒退。定稿文本可以是空白（断句器会忽略），但不能重复已经定稿过的文字。
4. `volatile` 事件携带尚未定稿音频的完整当前假设，并替换上一个。协调器在每次定稿时清空 `volatileText`，所以定稿之后如果还有假设，要再发一个新的 volatile。
5. 失败时用带错误的方式结束事件流。错误类型使用 `LocalizedError` 并给出可读的说明，因为协调器显示的是 `localizedDescription`。
6. 每场会议在音频开始之前调用一次 `preferredFormat`。
7. 引擎收到的 buffer 归它独占，不要假设它们会被复用。

## Translator / AppleTranslator（Task 8）

1. `translateBatch` 按输入顺序返回结果，数量与输入相同。只要有一部分失败，就让整批抛错；队列随后会逐句重试。不要返回占位内容。
2. `translate` 必须抛错，而不是返回空字符串或乱码。存下来的译文永远不再改变。可以考虑让队列把空结果也当作失败。
3. 绝不能挂起。模型不可用时要抛错，包括 App 在后台时。目前这种失败会被永久标记为 `translationFailed`；设计里的“回到前台后再补上”以后需要一轮重试。
4. 调用来自队列的 nonisolated 上下文，而不是主 actor。如果 26/27 SDK 中的 `TranslationSession` 不是 Sendable 或绑定在主 actor 上，在 AppleTranslator 内部用一个 actor 包起来。
5. `context` 可以忽略。

## ReadinessChecking / ModelReadiness（Task 8）

1. `preflight` 要快、完全离线，并且只抛 `ReadinessFailure`；其他任何错误都只会显示通用提示。
2. 协调器从不调用 `selfTest`。

## AudioSource / AudioCapture（Task 9）

与 `Sources/MeetingCore/Pipeline/AudioSource.swift` 中协议文档注释一致：

1. 每个 yield 出去的 buffer 都是新对象，来源此后再也不碰它（从 AVAudioEngine 的 tap 或转换器 buffer 中先拷贝出来再 yield）。
2. 流在 `stop()` 时、以及系统中断或音频路由丢失时结束；结束后不再 yield 任何东西。
3. `stop()` 幂等，在流已自行结束后、以及 `start` 之前调用都安全；它不能丢弃已采集到的 buffer（先把它们 yield 出去，再结束流）。协调器在 `stop()` 后最多等 1 秒让流自行结束，超时才强行切断。
4. 运行中再次调用 `start` 必须抛错，或先结束上一个流。
5. 输出格式与传给 `start` 的 `format` 完全一致。

## 未完成事项（本轮没有修）

- `SessionCoordinator` 收尾时识别流和翻译的排空都需要时间上限：一个永不结束事件流的引擎，或一次永不返回的翻译调用，会让状态永远停在 `.finishing`，`finish()` 不返回，`start` 也不再生效。上限值需要真机数据，必须在 Task 11 验收之前完成。同时补一个“引擎永不结束”的测试（它也能单独验证音频结束这一触发路径）。
- `TranscriptStore` 应改用 `container.mainContext`（将来的界面用 `@Query` 读取），并且在第一次装到真机之前，模型需要 `VersionedSchema` / `SchemaMigrationPlan`。
- 小问题：
  - `audio.start` 在会议已创建之后失败时，历史里会留下一场空的、已结束的会议。
  - 被中断的会议没有 `endReason`。
  - `hint(for:)` 显示的是 `localizedDescription`。
  - `append` 每次对所有句子求 max+1（2 小时会议是 O(n²)，在 Phase 2 测量）。
  - 加入收尾上限后，`SessionCoordinator+WrapUp.swift` 可能需要继续拆分（收尾路径已从 `+Pipeline` 移出）。
  - 把 `backlogThreshold` 限制为至少 1。
  - 考虑在 `finish` 之后调用 `enqueue` 时加 `assertionFailure`。
