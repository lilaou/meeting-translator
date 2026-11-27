# 引擎与音频来源的约定（Task 7 / 8 / 9）

这些约定来自对核心包 `Packages/MeetingCore` 的整支分支复审。`SessionCoordinator`、`TranslationQueue` 和 `SentenceAssembler` 依赖它们，接下来实现真实引擎的人必须遵守。

注意：协调器一侧的识别流收尾和翻译收尾已有时间上限（Task 11a-2），见“未完成事项”。Task 11（App 与界面）的作者请先读文末的“Task 11 作者须知”“真机验证清单”和“待定的设计决定”。

## ASREngine（Task 7）

1. 输入音频流结束后，先送出剩下的所有定稿，再在有限时间内结束事件流。绝不能让事件流一直开着。
2. 消费方取消时（`onTermination`），取消并释放 analyzer。
3. `finalized` 事件之后不会再被修改。它的 `range` 以输入流开始为零点、单位是秒，而且不会倒退。定稿文本可以是空白（断句器会忽略），但不能重复已经定稿过的文字。
4. `volatile` 事件携带尚未定稿音频的完整当前假设，并替换上一个。协调器在每次定稿时清空 `volatileText`，所以定稿之后如果还有假设，要再发一个新的 volatile。
5. 失败时用带错误的方式结束事件流。错误类型使用 `LocalizedError` 并给出可读的说明，因为协调器显示的是 `localizedDescription`。
6. 每场会议在音频开始之前调用一次 `preferredFormat`。
7. 引擎收到的 buffer 归它独占，不要假设它们会被复用。

## Translator / AppleTranslator（Task 8）

1. `translateBatch` 按输入顺序返回结果，数量与输入相同。只要有一部分失败，就让整批抛错；队列随后会逐句重试（收尾超时后被放弃、已取消的请求除外）。不要返回占位内容。
2. `translate` 必须抛错，而不是返回空字符串或乱码。存下来的译文永远不再改变。可以考虑让队列把空结果也当作失败。
3. 绝不能挂起。模型不可用时要抛错，包括 App 在后台时。目前这种失败会被永久标记为 `translationFailed`；设计里的“回到前台后再补上”以后需要一轮重试。
4. 调用来自队列的 nonisolated 上下文，而不是主 actor。如果 26/27 SDK 中的 `TranslationSession` 不是 Sendable 或绑定在主 actor 上，在 AppleTranslator 内部用一个 actor 包起来。
5. `context` 可以忽略。

## ReadinessChecking / ModelReadiness（Task 8）

1. `preflight` 要快、完全离线，并且只抛 `ReadinessFailure`；其他任何错误都只会显示通用提示。
2. 协调器从不调用 `selfTest`。
3. `selfTest` 可能抛 `CancellationError`（调用方取消了任务，或音频/识别/翻译被取消），原样抛出，不会包装成 `selfTestFailed`；调用方必须把它当作“已取消”，不能当作失败。只有真正的自检问题才是 `ReadinessFailure.selfTestFailed(原因)`。（Task 11a-3）

## AudioSource / AudioCapture（Task 9）

与 `Sources/MeetingCore/Pipeline/AudioSource.swift` 中协议文档注释一致：

1. 每个 yield 出去的 buffer 都是新对象，来源此后再也不碰它（从 AVAudioEngine 的 tap 或转换器 buffer 中先拷贝出来再 yield）。
2. 流在 `stop()` 时、以及系统中断或音频路由丢失时结束；结束后不再 yield 任何东西。
3. `stop()` 幂等，在流已自行结束后、以及 `start` 之前调用都安全；它不能丢弃已采集到的 buffer（先把它们 yield 出去，再结束流）。协调器在 `stop()` 后最多等 1 秒让流自行结束，超时才强行切断。
4. 运行中再次调用 `start` 必须抛错，或先结束上一个流。
5. 输出格式与传给 `start` 的 `format` 完全一致。

## 未完成事项（本轮没有修）

- 【已完成，Task 11a-2】`SessionCoordinator` 收尾时识别流和翻译的排空都有了时间上限（`PipelineConfig.engineDrainTimeout`，默认 10 秒；`PipelineConfig.translationDrainTimeout`，默认 30 秒；两个默认值都是暂定的，要用真机数据再调）。识别流超时：取消引擎任务（事件流的 `onTermination` 随之取消 analyzer），仍然 flush 半句、存储并入队。翻译超时：放弃翻译队列（`TranslationQueue.abandon()`），已到的结果照常写入，其余句子保持“待翻译”（`pendingTranslation`）、原文已保存，但 Phase 1 没有重试，这些句子的译文之后不会再补上（见“待定的设计决定”）；之后才到的结果被丢弃、不再写入。被放弃的请求在整批失败后也不再逐句重试（任务已被取消，结果反正会被丢弃）。两种超时都照常执行 `endMeeting`、保留全部已存记录，最终状态为 `.failed`（“识别在会议结束时未能及时完成……”/“有 N 句尚未完成翻译（原文已保存）”，与其他错误合并为一条提示）。“引擎永不结束”的测试同时覆盖了 `finish()` 和音频自行结束两种触发路径。
- 【已完成，Task 11a-1】`TranscriptStore` 已改用 `container.mainContext`（界面用 `@Query` 读取，每次写入都在同一次主 actor 调用里保存，失败则回滚）。模型已有 `VersionedSchema` / `SchemaMigrationPlan`：`SchemaV1`（版本 1.0.0），`MeetingMigrationPlan` 目前没有迁移阶段；容器只由一个工厂 `MeetingStorage` 创建（`makeContainer(at:)` / `makeInMemoryContainer()`）。测试固定了 `SchemaV1` 中 `Meeting` 和 `Segment` 的全部属性名和关系名，改动模型必须新增 `SchemaV2` 和迁移阶段。
- 【已完成，Task 11a-3】`selfTest` 的取消：取消时原样抛出 `CancellationError`，不会被包装成 `selfTestFailed`；`OnboardingModel` 把它当作“已取消”而不是失败，并把调用方任务的取消转发给它启动的作业。
- 会议结束后仍未翻译的句子（`pendingTranslation` / `translationFailed`）没有补译路径，Phase 1 不做。
- 小问题：
  - `audio.start` 在会议已创建之后失败时，历史里会留下一场空的、已结束的会议。
  - 被中断的会议没有 `endReason`。
  - `hint(for:)` 显示的是 `localizedDescription`。
  - `append` 每次对所有句子求 max+1（2 小时会议是 O(n²)，在 Phase 2 测量）。
  - 加入收尾上限后，`SessionCoordinator+WrapUp.swift` 可能需要继续拆分（收尾路径已从 `+Pipeline` 移出）。
  - 把 `backlogThreshold` 限制为至少 1。
  - 考虑在 `finish` 之后调用 `enqueue` 时加 `assertionFailure`。

## Task 11 作者须知

以下是界面层（Task 11b–11e）必须遵守的约定；核心包无法替界面保证它们。

1. 在主 actor 上用 `MeetingStorage.makeContainer(at:)` 只创建一次 `ModelContainer`，并把同一个实例同时传给 `.modelContainer(_:)` 和 `TranscriptStore(container:)`。
2. 存储文件的 URL 应放在 Application Support 目录下，并且它的上级目录必须已经存在。
3. 视图只用 `@Query` 读取，绝不在 `mainContext` 上插入、修改、删除或保存（也不要用 `@Bindable` 编辑）：存储写入失败时会回滚整个主上下文，而下一次存储保存又会把别人未保存的修改一并提交。
4. `@Model` 对象只能在主 actor 上使用。
5. 实时字幕列表需要一个子视图，它的 `init(meetingID:)` 构造一个按 `meeting?.id` 过滤、按 `index` 排序的 `Query`。
6. `SessionCoordinator.State.finishing` 可能持续约 1 + 10 + 30 秒（音频、识别、翻译三个上限）：要显示这个状态并禁用按钮；状态回到 `.idle` 或 `.failed` 之前 `start` 会被忽略；要显示 `.failed(message)` 的文字，它可能用“；”连接了多个问题。
7. `OnboardingModel`、`preflight` 和 `coordinator.start` 使用同一个 `Locale`（当前选择的源语言，只来自 `LanguageSelection.language`）和同一个 `ModelReadiness` 实例。换语言会换一个 `OnboardingModel`：显示它的视图必须随实例换身份（`.id(ObjectIdentifier(onboarding))`，见 `OnboardingPage`），否则 `.task`、下载尝试和 `onDisappear` 不会绑定到新实例。
8. 界面出现时调用 `OnboardingModel.refresh()`，消失时调用 `cancel()`。
9. 处于 `.awaitingTranslationDownload` 时，用 `.translationTask` + `prepareTranslation()` 下载，并通过 `translationDownloadFinished(error:)` 恰好报告一次；`cancel()` 之后的报告会被丢弃。
10. `.translationTask` 的配置要由 `step == .awaitingTranslationDownload` 推导出来，这样 `cancel()` 才能停止下载；每次新的尝试都要创建新的配置（或使其失效），否则第二次尝试根本不会开始，模型会一直等待。
11. 下载的语言对必须是 `OnboardingModel.translationSource` → `OnboardingModel.translationTarget`（zh-Hans），与检查时用的完全一致。
12. 自检被取消后出现的 `.needsSetup(.installed, .installed)` 表示“再跑一次自检”，而不是“去下载”。
13. 只有用户自己的滚动（例如 `onScrollPhaseChange` 中的 interacting/decelerating）才调用 `ScrollFollowState.userScrolled`，并在底部留一些容差；内容增长和程序触发的滚动不能算，否则每来一行新字幕都会停止跟随。
14. `CaptionFormatting.elapsedText` 需要一个不断更新的 `now`（例如 `TimelineView`）和 `coordinator.startedAt`。
15. `PipelineConfig` 里的各个超时都是暂定值。
16. `ModelReadiness` 和协调器共用一个 `AppleTranslator` 时，一个卡住的调用会同时阻塞两者。
17. 听写期间设置 `isIdleTimerDisabled`，以及 Info.plist 的键（`NSMicrophoneUsageDescription`、`UIBackgroundModes: [audio]`），都属于 App target，而不是核心包。

另外：`OnboardingModel.isBusy` 为 true 时（作业运行中，或已取消的作业仍在收尾）应禁用“下载”/“重试”按钮。

## 真机验证清单（需要真机）

以下各项在本机（macOS 15）无法验证，装到真机后逐项确认：

- 取消时真实的 `AssetInventory` 安装、`SpeechAnalyzer` 和 `TranslationSession` 是抛 `CancellationError`、抛领域错误，还是忽略取消（`ModelReadiness.installSpeechPack` 目前把包括取消在内的所有安装错误都包装成 `ModelReadinessError.speechInstallFailed`）。
- `translationState(from: locale.language)` 检查的语言对是否就是视图的 `TranslationSession` 实际下载的语言对（en → zh-Hans）。
- iOS 26/27 上 zh-Hans 对 “en” 的名称是否为“英语”（目前只在 macOS 15 上验证过）。
- `engine.stop()` 以及 `onTermination → session.cancel()` 是否及时返回并释放 analyzer（协调器的取消路径依赖它）；被卡住的系统翻译会话在实际中的表现。
- 真实 SwiftUI 场景中 `@Query` 是否实时更新；存储和 `mainContext` 在 iOS 18/26 上的行为是否与 macOS 15 相同（包括 `mainContext` 不会让容器保持存活、并发创建容器会崩溃这两条实现者的结论）。
- 第一次真实的模式迁移（`SchemaV1` → `SchemaV2`）。
- `engineDrainTimeout` 10 秒 / `translationDrainTimeout` 30 秒是否合适。
- 下载成功后不需要再点一次就到「已就绪」(`.translationTask` 在配置变为 nil 时会取消它的动作任务，视图已用独立的 Task 把报告交给模型)。
- `cancel()` 时系统下载弹窗和下载是否真的随配置变 nil 而停止；若不停，第二次「下载」可能弹出第二个弹窗（过期报告已被丢弃）。
- 应用从后台回到前台后，之前的 `.ready` 可能已过期。已确认的决定（11d）：字幕页在开始会议前不另做检查，由协调器的 `preflight` 预检并在失败时进入 `failed`，字幕页提供“检查语言包”回到引导页。需真机确认这条路径在“语言包被系统回收”时表现正确。
- 字幕页（11d，以下均未在真机验证）：
  - `meeting?.id == meetingID` 谓词在真实 SQLite 存储上是否只返回该会议的行，并实时更新（含“开始 → 结束 → 再开始”切到新会议）。
  - iOS 26/27 上 `onScrollPhaseChange` 与几何回调的先后顺序：新字幕到达时仍跟随；向上轻扫会停止跟随；快速甩到底部会恢复跟随；手势进行中到达的新内容不会拉动列表。在底部按住时到达一行新字幕不会停止跟随（已知风险：增长可能让“是否在底部”短暂为否）；列表仍在惯性滑动时点“回到最新”后保持跟随（程序化滚动打断惯性时是否报告 `.animating` 需真机确认）。
  - `.defaultScrollAnchor(.bottom, for: .initialOffset)`：带着已有字幕出现时从底部开始；短会议的第一行字幕不应贴在屏幕底部；上翻阅读历史时内容增长不应使其位移。
  - “回到最新”在几千行之外是否真的到达最底部（`ScrollPosition.scrollTo(edge: .bottom)` 配合 LazyVStack）。
  - 系统发起的滚动（点状态栏回到顶部、VoiceOver 滚动）很可能以 `.animating` 阶段上报，不会被当作用户滚动：跟随保持开启，下一条字幕会把用户拉回底部。是否可接受，需要真机确认。
  - 跟随时每次内容变高都会再次调用 `scrollTo(edge: .bottom)`，而 `position` 可能已经是 `.bottom`：重复的相同调用是否仍会重新滚动，需要真机确认（与上一条“回到最新”一并检查）。
  - 录音期间 `isIdleTimerDisabled` 在前后台切换、锁屏解锁后是否保持，结束或失败后是否已清除。
  - 2 小时会议中频繁的临时识别更新下，主线程是否流畅。
  - “检查语言包 → 引导页 → 开始”的往返流程。
- 【有条件】当 `speechState` 已经报告 `.installed`（系统早已有该模型）时，引导流程从不调用 `installSpeechPack`，因此该语言区域从未被预留（reserve）。如果转写必须先预留，自检就会一直失败，`retry()` 也修不好。可在真机上尝试的补救：让语音状态检查在语言区域未同时被预留时报告 `.notInstalled`；或在 `setUp` 中总是调用幂等的 `installSpeechPack`，并把自检失败引导回 `.needsSetup`。

### 韩语（均未在 iPhone 上验证）

在 MacBook Air（macOS，不是 iPhone）上查到 `SpeechTranscriber.supportedLocales` 含 `ko-KR`、韩语到 `zh-Hans` 的翻译状态为 `supported`；iPhone 上要逐项确认：

- 韩语语音识别包能否下载、安装（包括语言区域预留）。
- 韩语 → 中文翻译包能否通过 `.translationTask` 下载；下载的语言对（`ko-KR` 的 `Locale.Language`）与状态检查是否一致。
- 设备上是否有 `ko-KR` 的语音合成声音（没有时自检会报“本机没有“ko-KR”的语音合成声音。”）。
- 韩语自检能否通过：合成语音的识别结果里是否原样出现关键词“회의”（例如分写或字母分解会让它匹配不到）。
- 韩语识别和翻译的质量；识别结果是否带 `.`、`?` 等句末标点（不带时只能靠停顿和长度切句）。
- 200 字符上限和 2 秒停顿对韩语是否合适。
- 英语和韩语的语言包能否同时保留（`AssetInventory` 的预留数量有上限，这里从不释放预留）。
- 引导页换语言：分段控件换语言后新语言会自动检查（`.task` 重新执行），切换过程中没有旧语言的下载弹窗或状态残留；从字幕页“更换语言”返回时，当前语言会先重跑一次自检，期间分段控件不可用。

## 待定的设计决定

- `translationDrainTimeout`（默认 30 秒）限制的是会议结束时剩下的**全部**待翻译句子，而不是某一个卡住的调用；而 Phase 1 没有重试。因此会议结束时翻译若明显滞后，剩余句子的译文就永久缺失：这些行一直显示“…”，原文已保存。建议的方向（在真机验收之前决定，**目前没有实现**）：改为“没有进展”才超时的上限，每收到一个结果就重新计时；再加上剩余句子数，让界面可以显示“正在完成翻译…”。此项仍待决定。
