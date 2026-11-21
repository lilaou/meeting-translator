# 离线会议字幕翻译（Phase 0 + Phase 1）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先在真机上验证 Apple 原生识别和翻译的前提，再做出一个飞行模式下能把英语会议实时显示为中文字幕的 iPhone App。

**Architecture:** 纯逻辑和引擎放在本地 Swift 包 `MeetingCore` 里，用 `swift test` 在 Mac 上直接测；App 目标只含 SwiftUI 界面和装配。管线是 `AudioCapture → ASREngine → SentenceAssembler → TranslationQueue → TranscriptStore`，识别和翻译引擎藏在协议后面。

**Tech Stack:** Swift 6、SwiftUI、SwiftData、Speech（`SpeechAnalyzer`/`SpeechTranscriber`）、Translation（`TranslationSession`）、AVFoundation、Swift Testing、XcodeGen。无第三方运行时依赖。

**Spec:** `docs/superpowers/specs/2026-11-20-meeting-translator-design.md`

**范围：** 本计划覆盖规格的 Phase 0 和 Phase 1。Phase 2（历史页、导出、暂停与中断恢复、语言包管理页、2 小时稳定性）在 Phase 1 验收后另写计划。

## Global Constraints

- 所有构建、测试、真机步骤都在 Mac 上执行。Windows 上只能编辑文件。
- 目标设备 iPhone 18 Pro Max，iOS 27。部署目标 iOS 26.0；`MeetingCore` 同时声明 macOS 26.0，以便 `swift test`。
- 单个源文件不超过 200 行。
- 不引入第三方依赖；App 内不出现任何网络代码。
- 目标语言固定为简体中文：`Locale.Language(identifier: "zh-Hans")`。
- 首版源语言为英语（`en-US`）；一场会议只有一种源语言。
- 临时结果不翻译；译文一旦显示不再修改；任何情况下不丢已定稿的句子。
- 不保存原始录音。
- 测试用 Swift Testing（`import Testing`）。包测试命令：`swift test --package-path Packages/MeetingCore`。
- 分支：Task 1 建仓后，全部工作在 `feature/phase1-pipeline` 上进行。
- Speech 和 Translation 的 API 名称以实现时的官方文档为准。本计划写出的系统 API 名称来自 iOS 26 文档，iOS 27 SDK 如有出入，按文档改，协议和测试不变。
- 暂定参数（Phase 0 结果出来后在 Task 2 校准）：切句长度上限 200 字符，停顿时限 2 秒，翻译积压阈值 5 句，上下文句数 3。

## Review Focus

1. 小数和缩写里的句点（"3.5 percent"、"U.S. market"）：不应被切成两句。→ Task 4
2. 某一句翻译抛错：该句标记失败并保留原文，后面的句子照常翻译。→ Task 6
3. 识别引擎吐出空白或纯空格的定稿片段：不产生空字幕行。→ Task 4
4. 语言包在两次会议之间被系统回收：开始会议时进入 `failed` 并给出可读的提示，不崩溃。→ Task 10
5. 会议中途音频流意外结束（来电、被其他 App 抢占）：缓冲中的半句被切出并保存，会议正常收尾，已有记录完整。→ Task 10

---

## 文件结构

```
project.yml                              XcodeGen：App 目标 MeetingTranslator
Probe/                                   Phase 0 一次性验证程序（自带 project.yml，不进正式工程）
Packages/MeetingCore/
  Package.swift
  Sources/MeetingCore/
    Engines/ASREngine.swift              ASREvent、ASREngine 协议
    Engines/Translator.swift             Translator 协议 + 批量默认实现
    Engines/Apple/AppleSpeechEngine.swift
    Engines/Apple/AppleTranslator.swift
    Engines/Apple/ModelReadiness.swift   ReadinessChecking 协议 + 实现
    Pipeline/SentenceAssembler.swift
    Pipeline/TranslationQueue.swift
    Pipeline/AudioCapture.swift          AudioSource 协议 + 实现
    Pipeline/SessionCoordinator.swift
    Pipeline/PipelineConfig.swift
    Storage/Models.swift                 Meeting、Segment、SegmentStatus
    Storage/TranscriptStore.swift
    Resources/selftest-en.wav
  Tests/MeetingCoreTests/
    Fakes.swift                          FakeASREngine、FakeTranslator、FakeAudioSource、FakeReadiness
    SentenceAssemblerTests.swift
    TranscriptStoreTests.swift
    TranslationQueueTests.swift
    SessionCoordinatorTests.swift
MeetingTranslator/
  App/MeetingTranslatorApp.swift
  App/Info.plist
  Features/Onboarding/OnboardingView.swift
  Features/LiveCaption/LiveCaptionView.swift
  Features/LiveCaption/SegmentRow.swift
docs/phase0-results.md
```

---

## Phase 0

### Task 1: 建仓与真机验证程序

**Files:**
- Create: `.gitignore`、`Probe/project.yml`、`Probe/Probe/ProbeApp.swift`、`Probe/Probe/ProbeView.swift`、`Probe/Probe/SpeechProbe.swift`、`Probe/Probe/TranslationProbe.swift`、`Probe/Probe/SoakLogger.swift`、`Probe/Probe/Info.plist`
- Create: `docs/phase0-results.md`

**Interfaces:**
- Produces: `docs/phase0-results.md`，Task 2 读取它来校准参数和决定是否继续。

Probe 是一次性代码，不写测试，不追求结构，只求把规格第 7 节的六个问题问出来。

- [ ] **Step 1: 建仓。** `git init`；`.gitignore` 忽略 `*.xcodeproj`、`.build/`、`DerivedData/`、`.DS_Store`、`recordings/`。把现有文档提交到 `main`，然后 `git checkout -b feature/phase1-pipeline`。

- [ ] **Step 2: 写 Probe 工程。** `Probe/project.yml`：iOS App，部署目标 26.0，Bundle ID `com.local.MeetingProbe`。`Info.plist` 含 `NSMicrophoneUsageDescription`、`UIBackgroundModes: [audio]`、`UIFileSharingEnabled: true`（便于取回日志）。

- [ ] **Step 3: 实现 `ProbeView`，一屏六个按钮，每个按钮的输出追加到屏幕上的日志区和 `Documents/probe.log`：**

  | 按钮 | 行为 |
  |---|---|
  | 列出识别语言 | 打印 `SpeechTranscriber.supportedLocales` 和 `installedLocales` 的 BCP-47 标识 |
  | 列出翻译状态 | 对 `en`、`ko`、`ms`、`ja` 分别打印 `LanguageAvailability().status(from:to: zh-Hans)` |
  | 下载英语包 | 用 `AssetInventory.assetInstallationRequest(supporting:)` 下载识别资源；用 `.translationTask` + `prepareTranslation()` 触发翻译包下载 |
  | 文件识别+翻译 | 用文件选择器选一段音频，跑识别；每条结果打印 `[音频时间] [墙钟耗时] volatile/final 文本`；每条 final 立刻翻译并打印译文和翻译耗时 |
  | 麦克风长跑 | 持续识别+翻译；`SoakLogger` 每 60 秒记录一行：已运行分钟数、`phys_footprint`（MB）、`ProcessInfo.thermalState`、电量百分比、累计 final 条数、当前待翻译条数 |
  | 停止 | 结束长跑，写出汇总 |

- [ ] **Step 4: 构建并装到真机。** `cd Probe && xcodegen generate && open Probe.xcodeproj`，选自己的 Team，Run 到 iPhone 18 Pro Max。预期：App 打开，六个按钮可点。

- [ ] **Step 5: 人工执行验证并填写 `docs/phase0-results.md`。** 模板如下，逐项填实测值：

  ```markdown
  # Phase 0 真机验证结果
  设备 / 系统版本 / 日期：
  ## 1 识别语言：supportedLocales = …；en-US / ko-KR / ms-MY 是否在内：
  ## 2 翻译状态：en→zh-Hans / ko→zh-Hans / ms→zh-Hans：
  ## 3 飞行模式：下载后开飞行模式并重启 App，文件识别+翻译是否跑通：
  ## 4 质量与延迟（公开基准录音 + 自己的会议录音各至少一段）：
     - 主观判断能不能用：
     - 讲话到 volatile 出现的延迟：    volatile 到 final 的延迟：
     - final 片段的典型长度（字符）和是否带标点：
     - 单句翻译耗时（中位数 / 最大）：
  ## 5 麦克风长跑 120 分钟：内存起止值 / 最高 thermalState / 耗电 / 是否被杀：
  ## 6 后台与锁屏：锁屏 5 分钟后识别是否继续；翻译是否继续：
  ## 结论：方案 A 继续 / 回到方案选择
  ```

  公开基准录音由执行者挑选一段许可允许再分发的英语会议或讲座录音，放在 `Packages/MeetingCore/Tests/Fixtures/`；自己的会议录音放 `recordings/`（已被忽略）。

- [ ] **Step 6: 判定。** 按规格第 7 节退出条件判定。第 1–3 条对英语任一不通过，或第 4、5 条判为不通过：**停止，不要继续 Task 2**，把结果交回需求方重新选方案。

- [ ] **Step 7: Commit。** `git add Probe docs/phase0-results.md .gitignore && git commit -m "chore: add Phase 0 device probe and results"`

---

## Phase 1

### Task 2: 包骨架、核心协议、配置与假实现

**Files:**
- Create: `Packages/MeetingCore/Package.swift`、`Engines/ASREngine.swift`、`Engines/Translator.swift`、`Pipeline/PipelineConfig.swift`
- Test: `Tests/MeetingCoreTests/Fakes.swift`、`Tests/MeetingCoreTests/FakesTests.swift`

**Interfaces:**
- Consumes: `docs/phase0-results.md` 第 4 项（final 片段长度、翻译耗时）用来校准 `PipelineConfig` 默认值。
- Produces:

```swift
public enum ASREvent: Sendable, Equatable {
    case volatile(text: String)
    case finalized(text: String, range: ClosedRange<TimeInterval>)
}
public protocol ASREngine: Sendable {
    func supportedLocales() async -> [Locale]
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale)
        -> AsyncThrowingStream<ASREvent, Error>
}
public protocol Translator: Sendable {
    func canTranslate(from source: Locale.Language) async -> Bool
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String
    /// 返回数组与输入等长、同序。默认实现逐句调用 translate。
    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String]
}
public struct PipelineConfig: Sendable {
    public var maxSentenceCharacters = 200
    public var pauseTimeout: Duration = .seconds(2)
    public var backlogThreshold = 5
    public var contextSize = 3
    public init() {}
}
```

  `translateBatch` 是对规格 5.3 协议的补充，用来落实规格 5.4 第 5 条的批量请求。

  测试目标内的假实现：
  - `FakeASREngine(events: [ASREvent], error: Error? = nil)`：忽略音频，按顺序发出事件后结束或抛错。
  - `FakeTranslator(failing: Set<String> = [], delay: Duration = .zero)`：返回 `"译:" + text`；`failing` 里的原文抛 `FakeError.translation`；记录每次调用的 `batchSizes: [Int]`。
  - `FakeAudioSource`、`FakeReadiness` 在 Task 9、Task 8 定义协议后补上。

- [ ] **Step 1: 写 `Package.swift`。** 库目标 `MeetingCore`，测试目标 `MeetingCoreTests`，`platforms: [.iOS(.v26), .macOS(.v26)]`，Swift 语言模式 6，资源目录 `Resources`。
- [ ] **Step 2: 写失败的测试 `FakesTests.swift`：**

```swift
@Test func fakeEngineEmitsEventsInOrder() async throws {
    let events: [ASREvent] = [.volatile(text: "hel"), .finalized(text: "Hello.", range: 0...1)]
    let engine = FakeASREngine(events: events)
    var got: [ASREvent] = []
    for try await e in engine.transcribe(AsyncStream { $0.finish() }, locale: Locale(identifier: "en-US")) { got.append(e) }
    #expect(got == events)
}
@Test func defaultBatchTranslatesEachInOrder() async throws {
    let t = FakeTranslator()
    let out = try await t.translateBatch(["a", "b"], from: .init(identifier: "en"), context: [])
    #expect(out == ["译:a", "译:b"])
}
```

- [ ] **Step 3: 运行，确认失败。** `swift test --package-path Packages/MeetingCore`，预期编译失败（类型未定义）。
- [ ] **Step 4: 实现协议、`PipelineConfig`、两个假实现。** 按 Phase 0 实测调整 `PipelineConfig` 默认值，并在文件内注释写明依据的数据。
- [ ] **Step 5: 运行，确认通过。**
- [ ] **Step 6: Commit。** `git commit -m "feat: add MeetingCore package with engine protocols and fakes"`

### Task 3: 存储模型与 TranscriptStore

**Files:**
- Create: `Storage/Models.swift`、`Storage/TranscriptStore.swift`
- Test: `Tests/MeetingCoreTests/TranscriptStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public enum SegmentStatus: String, Codable, Sendable {
    case pendingTranslation, translated, translationFailed, interruptionMarker
}
@Model public final class Meeting {   // id: UUID, title: String, startedAt: Date, endedAt: Date?,
}                                     // sourceLocaleID: String, segments: [Segment]（级联删除）
@Model public final class Segment {   // id: UUID, meeting: Meeting?, index: Int, sourceText: String,
}                                     // translatedText: String?, startTime/endTime: TimeInterval, statusRaw: String
public struct Sentence: Sendable, Equatable {
    public let text: String; public let start: TimeInterval; public let end: TimeInterval
}
@MainActor public final class TranscriptStore {
    public init(container: ModelContainer)
    public static func inMemory() throws -> TranscriptStore
    public func startMeeting(locale: Locale, at date: Date) throws -> UUID
    public func append(_ sentence: Sentence, to meetingID: UUID) throws -> UUID   // 返回 segment id；index 自增
    public func setTranslation(_ text: String, for segmentID: UUID) throws        // 状态 → translated
    public func markTranslationFailed(_ segmentID: UUID) throws
    public func endMeeting(_ meetingID: UUID, at date: Date) throws
    public func segments(of meetingID: UUID) throws -> [Segment]                  // 按 index 升序
}
```

  每个写方法内部立即 `context.save()`。会议标题默认用开始时间格式化。

- [ ] **Step 1: 写失败的测试：**

```swift
@MainActor @Test func appendAssignsIncreasingIndexAndPendingStatus() throws {
    let store = try TranscriptStore.inMemory()
    let m = try store.startMeeting(locale: Locale(identifier: "en-US"), at: .now)
    _ = try store.append(Sentence(text: "One.", start: 0, end: 1), to: m)
    _ = try store.append(Sentence(text: "Two.", start: 1, end: 2), to: m)
    let segs = try store.segments(of: m)
    #expect(segs.map(\.index) == [0, 1])
    #expect(segs.allSatisfy { $0.statusRaw == SegmentStatus.pendingTranslation.rawValue })
}
@MainActor @Test func setTranslationFillsTextAndStatus() throws { /* translatedText == "一。"，status == translated */ }
@MainActor @Test func markFailedKeepsSourceText() throws { /* sourceText 不变，translatedText == nil，status == translationFailed */ }
@MainActor @Test func setTranslationOnTranslatedSegmentIsIgnored() throws { /* 第二次调用不改变 translatedText */ }
@MainActor @Test func dataSurvivesNewContextOnSameContainer() throws { /* 用同一 container 新建 store，segments 仍在 */ }
```

- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现模型和 `TranscriptStore`。**
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: Commit。** `git commit -m "feat: add SwiftData transcript storage"`

### Task 4: SentenceAssembler

**Files:**
- Create: `Pipeline/SentenceAssembler.swift`
- Test: `Tests/MeetingCoreTests/SentenceAssemblerTests.swift`

**Interfaces:**
- Consumes: `Sentence`（Task 3）、`PipelineConfig.maxSentenceCharacters`（Task 2）
- Produces:

```swift
public struct SentenceAssembler: Sendable {
    public init(maxCharacters: Int)
    /// 接收一个定稿片段，返回因此切出的完整句子（可能 0 到多句）
    public mutating func ingest(text: String, range: ClosedRange<TimeInterval>) -> [Sentence]
    /// 把缓冲里剩下的内容作为一句切出；缓冲为空返回 nil
    public mutating func flush() -> Sentence?
    public var hasPending: Bool { get }
}
```

  切句规则（签名和测试不足以确定，这里写明）：
  1. 片段先去首尾空白；为空则忽略。追加到缓冲时，与已有内容之间补一个空格（缓冲以 CJK 字符结尾时不补）。
  2. 句末符：`。？！` 总是成立；`.?!` 只有后面紧跟空白或位于缓冲末尾时成立。
  3. 例外：`.` 的前后都是数字时不成立；`.` 前面的词是单个字母，或在缩写表 `Mr Mrs Ms Dr Prof vs etc e.g i.e` 内时不成立。
  4. 没有句末符而缓冲超过 `maxCharacters` 时，在不超过上限的最后一个空白处切；没有空白就在上限处硬切。
  5. 句子的 `start` 是组成它的第一个片段的 `lowerBound`，`end` 是最后一个片段的 `upperBound`。一个片段被切成多句时，这些句子共用该片段的时间范围。

  停顿时限不在这里处理：由 `SessionCoordinator` 计时并调用 `flush()`。

- [ ] **Step 1: 写失败的测试：**

```swift
@Test func piecesJoinUntilTerminator() {
    var a = SentenceAssembler(maxCharacters: 200)
    #expect(a.ingest(text: "We'll start the pilot", range: 0...2).isEmpty)
    let out = a.ingest(text: "run next Monday.", range: 2...4)
    #expect(out == [Sentence(text: "We'll start the pilot run next Monday.", start: 0, end: 4)])
    #expect(!a.hasPending)
}
@Test func onePieceWithTwoSentencesYieldsTwo() { /* "Okay. Let's begin." → 两句 */ }
@Test func decimalPointDoesNotSplit() { /* "Yield rose to 3.5 percent." → 一句 */ }
@Test func abbreviationDoesNotSplit() { /* "The U.S. market is next." 与 "Dr. Lee agrees." → 各一句 */ }
@Test func whitespaceOnlyPieceIsIgnored() { /* ingest("   ") 返回空且 hasPending == false */ }
@Test func overLimitCutsAtLastSpace() { /* maxCharacters: 20，无标点长文本：每句 count <= 20，拼回去等于原文 */ }
@Test func overLimitWithoutSpacesHardCuts() { /* 40 个连续字母，maxCharacters: 20 → 两句各 20 */ }
@Test func flushReturnsRemainderOnce() { /* ingest("and then") 后 flush() 返回该句，再 flush() 为 nil */ }
@Test func chineseTerminatorSplitsWithoutSpace() { /* "好的。开始吧。" → 两句 */ }
```

- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: Commit。** `git commit -m "feat: add sentence assembler"`

### Task 5: 用 Phase 0 的真实片段回放校验切句

**Files:**
- Create: `Tests/MeetingCoreTests/Fixtures/phase0-finals.json`、`Tests/MeetingCoreTests/AssemblerReplayTests.swift`

**Interfaces:**
- Consumes: `SentenceAssembler`（Task 4）；Probe 的 `probe.log` 中基准录音的 final 行。

- [ ] **Step 1: 从 `probe.log` 取基准录音的全部 final 片段，存成 `[{"text":…, "start":…, "end":…}]`。**
- [ ] **Step 2: 写回放测试：** 全部片段依次 `ingest` 后 `flush`；断言没有空句、没有句子超过 `maxSentenceCharacters`、所有句子拼接后去空白等于所有片段拼接后去空白。
- [ ] **Step 3: 运行。** 失败则回到 Task 4 修规则并补一条对应的单元测试，直到通过。
- [ ] **Step 4: 人工抽查。** 测试里把切出的句子打印出来，读前 30 句。如果系统识别引擎的 final 片段本身不带标点（见 Phase 0 结果第 4 项），在 `PipelineConfig` 里调低 `maxSentenceCharacters` 和 `pauseTimeout`，并把决定记在 `docs/phase0-results.md` 末尾。
- [ ] **Step 5: Commit。** `git commit -m "test: replay Phase 0 transcript through assembler"`

### Task 6: TranslationQueue

**Files:**
- Create: `Pipeline/TranslationQueue.swift`
- Test: `Tests/MeetingCoreTests/TranslationQueueTests.swift`

**Interfaces:**
- Consumes: `Translator`、`PipelineConfig`（Task 2）
- Produces:

```swift
public struct TranslationOutcome: Sendable {
    public let segmentID: UUID
    public let translation: String?      // nil 表示失败
}
public actor TranslationQueue {
    public init(translator: any Translator, source: Locale.Language, config: PipelineConfig)
    public nonisolated let outcomes: AsyncStream<TranslationOutcome>   // 严格按入队顺序
    public nonisolated let lagging: AsyncStream<Bool>                  // 仅在跨过阈值时发出
    public func enqueue(segmentID: UUID, text: String)
    /// 队列清空且在途请求完成后返回，并结束两个流
    public func finish() async
}
```

  行为：同一时刻只有一个在途请求。每次取出当前队列里的全部句子，用一次 `translateBatch` 送出，`context` 是最近 `contextSize` 句已送出的原文。批量请求抛错时，退回逐句 `translate`，单句再失败则该句 `translation == nil`。待翻译数 ≥ `backlogThreshold` 时发 `lagging(true)`，回落到阈值以下发 `lagging(false)`。

- [ ] **Step 1: 写失败的测试：**

```swift
@Test func outcomesFollowEnqueueOrder() async { /* 入队 a,b,c → outcomes 的 translation 依次 "译:a","译:b","译:c" */ }
@Test func backlogIsSentAsOneBatch() async {
    /* FakeTranslator(delay: .milliseconds(50))；先入队 1 句，紧接着入队 4 句；
       finish 后 translator.batchSizes == [1, 4] */
}
@Test func oneFailureDoesNotBlockOthers() async {
    /* FakeTranslator(failing: ["b"])；入队 a,b,c →
       outcomes: a 有译文，b 的 translation == nil，c 有译文，顺序不变 */
}
@Test func laggingTogglesAroundThreshold() async { /* backlogThreshold = 2，慢翻译器，入队 4 句 → lagging 先 true 后 false */ }
@Test func contextCarriesPreviousSources() async { /* contextSize = 2，逐句入队并等待 → 第三句请求的 context == ["a","b"] */ }
@Test func finishWaitsForInFlightWork() async { /* 入队后立刻 finish()，返回时 outcomes 已含全部句子且流已结束 */ }
```

  `FakeTranslator` 需补充记录每次调用收到的 `context`。

- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: Commit。** `git commit -m "feat: add ordered batching translation queue"`

### Task 7: AppleSpeechEngine

**Files:**
- Create: `Engines/Apple/AppleSpeechEngine.swift`、`Engines/Apple/AudioFileSource.swift`
- Test: `Tests/MeetingCoreTests/AppleSpeechEngineDeviceTests.swift`（仅真机，`.enabled(if:)` 以环境变量 `RUN_DEVICE_TESTS` 控制）

**Interfaces:**
- Consumes: `ASREngine`、`ASREvent`（Task 2）
- Produces:

```swift
public struct AppleSpeechEngine: ASREngine { public init() }
/// 把音频文件读成缓冲流，供回归和引擎对比使用
public func audioBuffers(fromFile url: URL, format: AVAudioFormat) throws -> AsyncStream<AVAudioPCMBuffer>
```

  实现要点：
  - `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`，开启 volatile 结果和音频时间范围。
  - `supportedLocales()` 返回 `SpeechTranscriber.installedLocales`（只报告真正可用的）。
  - `preferredFormat` 用 `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`。
  - `transcribe`：把缓冲包成 `AnalyzerInput` 送入分析器；遍历 `transcriber.results`，`isFinal` 为真映射为 `.finalized`（时间范围取结果的音频时间范围，换算成秒），否则 `.volatile`；文本用 `String(result.text.characters)`。输入流结束时调用分析器的"收尾并结束"方法，等剩余结果吐完再结束事件流。
  - 调用方取消事件流时取消分析器并释放。

- [ ] **Step 1: 写真机测试：** 用 `Fixtures/` 里的基准录音跑 `transcribe`；断言至少有一个 `.volatile` 和一个 `.finalized`，`.finalized` 的 `range` 单调不减，所有 final 文本拼接后包含该录音里三个预先挑好的关键词（忽略大小写）。
- [ ] **Step 2: 实现两个文件。**
- [ ] **Step 3: 确认包在 Mac 上能编译。** `swift build --package-path Packages/MeetingCore`，预期成功。
- [ ] **Step 4: 真机运行测试。** 在 Task 11 的 App 工程建好之前，把这个测试临时挂到 Probe 工程的测试目标上跑：`RUN_DEVICE_TESTS=1`，目标设备选 iPhone 18 Pro Max。预期通过。
- [ ] **Step 5: Commit。** `git commit -m "feat: add Apple speech engine"`

### Task 8: AppleTranslator 与 ModelReadiness

**Files:**
- Create: `Engines/Apple/AppleTranslator.swift`、`Engines/Apple/ModelReadiness.swift`、`Resources/selftest-en.wav`
- Test: `Tests/MeetingCoreTests/ModelReadinessDeviceTests.swift`（仅真机）；`Fakes.swift` 增加 `FakeReadiness`

**Interfaces:**
- Consumes: `Translator`、`ASREngine`、`audioBuffers(fromFile:format:)`
- Produces:

```swift
public struct AppleTranslator: Translator { public init() }

public enum PackState: Sendable, Equatable { case unsupported, notInstalled, installed }
public enum ReadinessFailure: Error, Sendable, Equatable {
    case speechPackMissing, translationPackMissing, selfTestFailed(String)
}
public protocol ReadinessChecking: Sendable {
    func speechState(for locale: Locale) async -> PackState
    func translationState(from source: Locale.Language) async -> PackState
    func installSpeechPack(for locale: Locale) async throws
    /// 实际跑一次识别和翻译；通过才算可离线使用
    func selfTest(locale: Locale) async throws
    /// 开会前的轻量检查：两个状态都为 installed，否则抛对应的 ReadinessFailure
    func preflight(locale: Locale) async throws
}
public struct ModelReadiness: ReadinessChecking {
    public init(engine: any ASREngine, translator: any Translator)
}
```

  实现要点：
  - `AppleTranslator`：每个源语言缓存一个 `TranslationSession(installedSource:target:)`；`translate` 忽略 `context`；`translateBatch` 用会话的批量接口，按请求顺序整理结果。
  - 翻译语言包的下载必须由 SwiftUI 的 `.translationTask` 触发，所以不在这里，放在 Task 11 的引导页。
  - `selftest-en.wav`：在 Mac 上生成，`say -v Samantha -o /tmp/s.aiff "The meeting will start at nine tomorrow morning."`，再 `afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/s.aiff selftest-en.wav`。
  - `selfTest`：识别该文件，final 文本须包含 `meeting`（忽略大小写）；翻译 `"The meeting will start at nine."`，结果须非空且含至少一个汉字。否则抛 `selfTestFailed(原因)`。
  - `FakeReadiness(preflightError: ReadinessFailure? = nil)`。

- [ ] **Step 1: 写真机测试：** 语言包已装时 `selfTest` 不抛错；`AppleTranslator().translateBatch(["Good morning.", "Thank you."], …)` 返回两条且都含汉字。
- [ ] **Step 2: 生成 `selftest-en.wav`，实现三个类型。**
- [ ] **Step 3: `swift build` 通过；真机测试通过（方式同 Task 7 Step 4）。**
- [ ] **Step 4: 真机飞行模式下再跑一次 `selfTest`，预期通过。**
- [ ] **Step 5: Commit。** `git commit -m "feat: add Apple translator and offline readiness checks"`

### Task 9: AudioCapture

**Files:**
- Create: `Pipeline/AudioCapture.swift`
- Test: `Fakes.swift` 增加 `FakeAudioSource`

**Interfaces:**
- Produces:

```swift
public protocol AudioSource: Sendable {
    /// 开始采集并以指定格式输出；流在 stop() 或系统中断时结束
    func start(format: AVAudioFormat) async throws -> AsyncStream<AVAudioPCMBuffer>
    func stop() async
}
public final class AudioCapture: AudioSource { public init() }
public enum AudioCaptureError: Error { case permissionDenied, engineStartFailed(String) }
```

  实现要点：申请麦克风权限，被拒抛 `permissionDenied`；`AVAudioEngine` 输入节点装 tap，用 `AVAudioConverter` 转成目标格式；监听音频会话中断通知，中断开始时结束流。音频会话的类别、模式和缓冲大小由实现者决定（规格第 10 节）。Phase 1 不做中断后恢复。

  `FakeAudioSource`：`start` 返回一个由测试控制的流，提供 `endStream()` 模拟中断，记录 `stopCallCount`。

- [ ] **Step 1: 实现 `AudioCapture` 和 `FakeAudioSource`。** 这个类只是系统 API 的薄封装，没有可在 Mac 上单测的逻辑，由 Task 11 的真机验收覆盖。
- [ ] **Step 2: `swift build` 通过。**
- [ ] **Step 3: Commit。** `git commit -m "feat: add microphone capture"`

### Task 10: SessionCoordinator

**Files:**
- Create: `Pipeline/SessionCoordinator.swift`（超过 200 行时把事件处理拆到 `Pipeline/SessionCoordinator+Pipeline.swift`）
- Test: `Tests/MeetingCoreTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 2–9 的全部产出。
- Produces:

```swift
@MainActor @Observable public final class SessionCoordinator {
    public enum State: Equatable { case idle, preparing, listening, finishing, failed(String) }
    public private(set) var state: State
    public private(set) var volatileText: String          // 当前临时原文；有定稿到达时清空
    public private(set) var isTranslationLagging: Bool
    public private(set) var meetingID: UUID?
    public private(set) var startedAt: Date?
    public init(engine: any ASREngine, translator: any Translator, audio: any AudioSource,
                readiness: any ReadinessChecking, store: TranscriptStore, config: PipelineConfig)
    public func start(locale: Locale) async
    public func finish() async
}
```

  行为：
  - `start`：`idle → preparing`；`readiness.preflight` 抛错则 `failed(可读的中文提示)`，不创建会议；通过则建会议、启动音频、识别、翻译队列，进入 `listening`。
  - `.volatile` 更新 `volatileText`。`.finalized` 送入 `SentenceAssembler`，切出的每句 `store.append` 后入翻译队列。
  - 停顿计时：连续 `config.pauseTimeout` 没有收到任何识别事件且 `hasPending` 时，调用 `flush()` 并按同样方式处理。
  - 翻译结果：有译文调 `setTranslation`，否则 `markTranslationFailed`。
  - 收尾（`finish()` 被调用、音频流自行结束、识别流抛错，三者同一条路径）：`finishing` → 停音频 → 等识别流结束 → `flush()` → `queue.finish()` → `endMeeting` → `idle`。识别流抛错时走完收尾后状态为 `failed(提示)`，已有记录保留。
  - `failed` 状态下再次 `start` 可以重新开始。

  Phase 1 没有 `paused` 状态（规格 5.5 的暂停与恢复属于 Phase 2）；Phase 1 遇到中断按"会议正常收尾"处理。

- [ ] **Step 1: 写失败的测试（全部用假实现和 `TranscriptStore.inMemory()`）：**

```swift
@MainActor @Test func finalizedSentencesAreStoredAndTranslated() async throws {
    /* 事件: volatile("we"), finalized("We start Monday.", 0...2), finalized("Thanks.", 2...3)
       start → 等待回到 idle → segments 两条，sourceText 与 translatedText("译:…") 一一对应，status == translated */
}
@MainActor @Test func volatileTextIsExposedAndClearedOnFinal() async throws { }
@MainActor @Test func preflightFailureGoesToFailedWithoutMeeting() async throws {
    /* FakeReadiness(preflightError: .translationPackMissing) → state 为 .failed 且提示非空，meetingID == nil */
}
@MainActor @Test func audioEndingMidSentenceFlushesAndSaves() async throws {
    /* 事件: finalized("and then we need", 0...2) 后音频流 endStream()
       → 最终 state == .idle，segments 含 "and then we need"，meeting.endedAt != nil */
}
@MainActor @Test func engineErrorKeepsStoredSegments() async throws {
    /* FakeASREngine 发出一句完整 final 后抛错 → state 为 .failed，该句仍在 store 且已翻译 */
}
@MainActor @Test func pauseTimeoutFlushesPendingText() async throws {
    /* config.pauseTimeout = .milliseconds(50)；引擎发出无标点 final 后保持流不结束
       → 100ms 内 segments 出现该句 */
}
@MainActor @Test func translationFailureMarksSegmentFailed() async throws { }
@MainActor @Test func finishDrainsQueueBeforeIdle() async throws { /* 慢翻译器；finish() 返回时所有 segment 已非 pending */ }
```

  为第 6 条测试，`FakeASREngine` 增加 `keepOpen: Bool` 选项。

- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 运行，确认全部包测试通过。** `swift test --package-path Packages/MeetingCore`
- [ ] **Step 5: Commit。** `git commit -m "feat: add session coordinator"`

### Task 11: App 界面、装配与真机验收

**Files:**
- Create: `project.yml`、`MeetingTranslator/App/MeetingTranslatorApp.swift`、`MeetingTranslator/App/Info.plist`、`MeetingTranslator/Features/Onboarding/OnboardingView.swift`、`MeetingTranslator/Features/LiveCaption/LiveCaptionView.swift`、`MeetingTranslator/Features/LiveCaption/SegmentRow.swift`
- Create: `docs/phase1-acceptance.md`

**Interfaces:**
- Consumes: `SessionCoordinator`、`TranscriptStore`、`ModelReadiness`、`AppleSpeechEngine`、`AppleTranslator`、`AudioCapture`、`Segment`。

  界面决定：
  - `project.yml`：App 目标 `MeetingTranslator`，Bundle ID `com.local.MeetingTranslator`，部署目标 iOS 26.0，依赖本地包 `Packages/MeetingCore`，测试目标挂上包里的真机测试。`Info.plist`：`NSMicrophoneUsageDescription`（"用于识别会议语音，音频不会离开本机"）、`UIBackgroundModes: [audio]`，支持横竖屏。
  - `MeetingTranslatorApp`：创建磁盘上的 `ModelContainer`，装配真实实现。`ModelReadiness.preflight(en-US)` 通过则进字幕页，否则进引导页。
  - `OnboardingView`（最简）：只有英语一行，显示识别包和翻译包各自的状态；"下载"按钮依次调 `installSpeechPack`、用 `.translationTask` + `prepareTranslation()` 下载翻译包、再跑 `selfTest`；自检通过显示"已就绪，可离线使用"和"开始"按钮，失败显示原因和"重试"。
  - `LiveCaptionView`：布局按规格 5.8 的示意。顶栏显示"英语 → 中文"、已用时间、"离线"标签，`isTranslationLagging` 为真时显示"翻译滞后"。列表用 `@Query` 按 `index` 读当前会议的 `Segment`；末尾一行显示 `volatileText`（次要颜色）。新内容到达时自动滚到底；用户上翻后停止自动滚动并出现"回到最新"按钮。底部在 `idle`/`failed` 时显示"开始会议"，在 `listening` 时显示"结束会议"。`failed` 时显示提示文字。`listening` 期间 `isIdleTimerDisabled = true`，离开时恢复。
  - `SegmentRow`：原文小字在上，译文大字在下；`pendingTranslation` 时译文位置显示"…"，`translationFailed` 时显示"（翻译失败）"。
  - Phase 1 不做暂停按钮、字号调整、历史页。

- [ ] **Step 1: 写 `project.yml`、`Info.plist` 和 App 入口；`xcodegen generate`；在模拟器上构建通过。**
- [ ] **Step 2: 实现 `OnboardingView`。**
- [ ] **Step 3: 实现 `LiveCaptionView` 和 `SegmentRow`。** 用 SwiftUI Preview 配假数据检查三种行状态和临时行的显示。
- [ ] **Step 4: 真机运行 Task 7、Task 8 的真机测试。** `xcodebuild test -scheme MeetingTranslator -destination 'platform=iOS,name=<设备名>'`，环境变量 `RUN_DEVICE_TESTS=1`。预期通过。
- [ ] **Step 5: 真机验收，结果逐项记入 `docs/phase1-acceptance.md`：**

  | # | 操作 | 预期 |
  |---|---|---|
  | 1 | 全新安装，联网完成引导 | 显示"已就绪，可离线使用" |
  | 2 | 开飞行模式，杀掉并重启 App | 直接进入字幕页 |
  | 3 | 飞行模式下开始会议，用另一台设备播放基准录音 10 分钟 | 原文实时出现；每句定稿后出现中文；已显示的译文不变化 |
  | 4 | 对照 Probe 日志里同一段录音的 final 文本 | 没有缺句 |
  | 5 | 会议中强杀 App，重启后用 Xcode 查看数据容器或临时加日志 | 强杀前已定稿的句子都在 |
  | 6 | 会议中给手机打电话 | 会议收尾，状态回到可重新开始，记录完整 |
  | 7 | 在系统设置里删除英语识别资源后点"开始会议" | 显示可读的错误提示，不崩溃 |
  | 8 | 用 Xcode 的网络调试工具观察一场会议 | App 无任何网络请求 |

- [ ] **Step 6: 任何一项不通过：** 用 superpowers:systematic-debugging 找到原因，在对应任务的测试里补一条能复现它的用例，修复后重跑整张表。
- [ ] **Step 7: Commit。** `git commit -m "feat: add onboarding and live caption UI with device acceptance"`

---

## 自检记录

- **规格覆盖：** 规格 5.1–5.4、5.6、5.7 由 Task 2–10 覆盖；5.5 的 `paused` 与中断恢复、5.8 的历史页、字号、暂停按钮、导出，以及 2 小时稳定性验收属于 Phase 2，不在本计划内。第 6 节扩展路径不实现，只由协议边界保证。
- **与规格的两处差异：** `Translator` 增加 `translateBatch`（落实批量请求）；Phase 1 的状态机没有 `paused`（中断按正常收尾处理）。
- **暂定数值：** `PipelineConfig` 的四个默认值在 Task 2 和 Task 5 按 Phase 0 数据校准。
