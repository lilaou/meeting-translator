# 面对面翻译（中文 ↔ 韩语）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 两人面对面用一台 iPhone：按各自的按钮说话，一半屏幕显示中文、倒置的另一半显示韩语。

**Architecture:** 核心包新增两个不依赖 SwiftUI 的状态机（一次说话 `ConversationSession`、四样语言包 `ConversationPacks`），复用 `ASREngine`、`AudioSource`、`Translator`；`AppleTranslator` 增加目标语言参数；App 只做显示和转发点击。会议字幕的行为和存储结构不变。

**Tech Stack:** Swift 6、SwiftUI、Observation、Speech（`SpeechAnalyzer`）、Translation、Swift Testing、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-11-27-face-to-face-design.md`

## Global Constraints

- 部署目标 iOS 26.0；Swift 6 语言模式；警告当错误；单个源文件不超过 200 行；无第三方依赖；无网络代码。
- 只做中文 ↔ 韩语，只显示文字；不朗读、不自动识别语言、对话不保存、不写 SwiftData。
- 中文识别 `zh-CN`，韩语识别 `ko-KR`，翻译语言对恰好是 `zh-Hans` ↔ `ko`，定义只写在一处。
- 停顿 2 秒（`PipelineConfig().pauseTimeout`）、无任何识别文字 8 秒、单次上限 60 秒。
- 绝不悄悄释放其他语言的识别“保留”。
- `#if compiler(>=6.2)` + `@available(iOS 26.0, macOS 26.0, *)` 包住 Apple 引擎代码；这些和 App 只有 CI 能编译。本地命令 `swift test --package-path Packages/MeetingCore`。
- 不读取、不提交仓库根目录的 `macbookair.md`。
- 提交信息结尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。
- 并发：不用 `@unchecked Sendable`；不在非隔离闭包里捕获 `[weak self]` 再切 `@MainActor`（Swift 6.3.3 拒绝）；SwiftUI 会取消 `.task`/`.translationTask` 的任务，跨页面生存的工作用独立 `Task`。

## Review Focus

- 录音还在启动时又点了一次（本方或对方）：不得出现两次录音，也不得停不下来。
- 录音启动中或翻译未返回时离开页面：麦克风关掉，迟到的结果不出现在清空后的对话里。
- 识别结束时只有临时文字、没有定稿：这些字不能丢。
- 中文片段拼接不加空格，韩语片段之间保留空格。
- 来电打断后切到后台再回来：已听到的话保留并翻译，不丢、不重复。

---

### Task 1: 翻译指定目标语言与语言常量

**Files:**
- Create: `Packages/MeetingCore/Sources/MeetingCore/Conversation/ConversationLanguages.swift`
- Modify: `Engines/Apple/AppleTranslator.swift`
- Test: `Tests/MeetingCoreTests/ConversationLanguagesTests.swift`

**Interfaces — Produces:**
- `public enum ConversationSide: String, Sendable, CaseIterable { case chinese, korean; public var other: ConversationSide; public var speechLocale: Locale; public var translationLanguage: Locale.Language }`
- `public init(target: Locale.Language)` 于 `AppleTranslator`；现有 `public init()` 行为不变（目标仍是 `TranslationTarget.language`）。
- `static func packState(from: Locale.Language, to: Locale.Language) async -> PackState`

- [ ] 写失败测试 `sidesUseTheAgreedIdentifiers`：`ConversationSide.chinese.speechLocale.identifier(.bcp47) == "zh-CN"`，`.korean` 为 `"ko-KR"`；`translationLanguage` 等于 `Locale.Language(identifier: "zh-Hans")` / `"ko"`；`chinese.other == .korean`。运行，确认因类型不存在而失败。
- [ ] 实现 `ConversationLanguages.swift`；测试通过。
- [ ] `AppleTranslator`：保存 `target`，会话缓存仍按源语言（每个实例只有一个目标），`TranslationSessions`、`packState`、`canTranslate`、`cachedSession` 全部用实例的目标；`ApplePackStates.translationState(from:)` 仍传 `TranslationTarget.language`。更新类型文档注释（不再写“always into Simplified Chinese”）。
- [ ] 本地测试全过；提交 `feat(core): translate into a chosen target and name the conversation languages`。

### Task 2: `ConversationSession`（一次说话的状态机）

**Files:**
- Create: `Conversation/ConversationSession.swift`、`Conversation/ConversationSession+Turn.swift`、`Conversation/ConversationText.swift`
- Test: `Tests/MeetingCoreTests/ConversationSessionTests.swift`、`ConversationFakes.swift`（沿用 `Fakes.swift`、`SessionFakes.swift` 里的假引擎、假音频、假翻译和 gate，不改它们的行为）

**Interfaces — Consumes:** `ConversationSide`；`ASREngine`、`AudioSource`、`Translator`。
**Produces:**
```swift
public struct ConversationUtterance: Identifiable, Equatable, Sendable {
    public let id: Int
    public let speaker: ConversationSide
    public let original: String
    public let translation: String?      // nil = 翻译失败
}
public struct ConversationTiming: Sendable {
    public var pause: Duration = .seconds(2)
    public var silence: Duration = .seconds(8)
    public var maximum: Duration = .seconds(60)
    public init()
}
@MainActor @Observable public final class ConversationSession {
    public enum Phase: Equatable, Sendable { case idle, starting(ConversationSide), listening(ConversationSide), finishing(ConversationSide) }
    public enum Notice: Equatable, Sendable { case notHeard, failed(String) }
    public private(set) var phase: Phase
    public private(set) var liveText: String
    public private(set) var utterances: [ConversationUtterance]
    public private(set) var notice: Notice?
    /// `translator(side)` 把 side 说的话译成对方的语言。
    public init(engine: any ASREngine, audio: any AudioSource,
                translator: @escaping @Sendable (ConversationSide) -> any Translator,
                timing: ConversationTiming)
    public func tap(_ side: ConversationSide) async   // idle→开始；本方 starting/listening→结束；其余忽略
    public func enterBackground()                     // starting/listening：丢弃本次；finishing：翻译推迟
    public func enterForeground()
    public func leave() async                         // 停止、丢弃、清空 utterances
}
```
`finishing` 覆盖识别收尾和翻译。翻译的 `from` 是说话方的 `translationLanguage`，`context` 传空数组。`ConversationText.join(_:)` 去掉各段首尾空白，两侧都不是汉字/中日韩标点时补一个空格（复用 `SentenceAssembler` 里的判断，必要时把它改为 internal static）。

- [ ] 写失败测试（时间参数用毫秒级，同步用 gate，不用固定睡眠做断言）：
  - `aTurnShowsTheOriginalAndTheTranslation`：中文方 tap→（假引擎定稿 "你好"）→tap；`utterances == [.init(id: 0, speaker: .chinese, original: "你好", translation: "译:你好")]`，`phase == .idle`，音频 stop 一次。
  - `tapsWhileStartingNeverStartASecondRecording`：音频 start 卡在 gate；本方、对方各再 tap；放行后 start 次数为 1；本方那次 tap 记为“结束”，最终回到 idle 且 stop 一次。
  - `theOtherSideIsIgnoredWhileListening`
  - `aPauseEndsTheTurn`、`silenceWithoutTextEndsWithNotHeard`（`utterances` 为空、`notice == .notHeard`）、`theMaximumEndsTheTurn`
  - `volatileOnlyTextIsKept`：只有 volatile "안녕" → 结束后 `original == "안녕"`。
  - `piecesAreJoinedByLanguage`：中文 ["今天","很好。"] → "今天很好。"；韩语 ["오늘은","좋아요."] → "오늘은 좋아요."。
  - `aFailedTranslationKeepsTheOriginal`：`translation == nil`。
  - `anEngineErrorKeepsWhatWasHeard`，以及无文字时 `notice == .failed(说明)`；`audioStartFailureIsReported`。
  - `anEndedAudioStreamFinishesTheTurn`（模拟来电）。
  - `backgroundWhileListeningDropsTheTurn`；`backgroundAfterTheAudioEndedDefersTheTranslationUntilForeground`（翻译调用次数在 foreground 前为 0，之后恰好 1）。
  - `leaveWhileStartingTurnsTheMicrophoneOff`；`aLateTranslationAfterLeaveIsDropped`（翻译卡在 gate，leave 后放行，`utterances` 仍为空）。
- [ ] 运行，确认失败；实现；全部通过；连续跑 10 次稳定。
- [ ] 提交 `feat(core): add the face-to-face turn state machine`。

### Task 3: `ConversationPacks`（四样语言包）

**Files:**
- Create: `Conversation/ConversationPacks.swift`、`Engines/Apple/ModelReadiness+Conversation.swift`
- Test: `Tests/MeetingCoreTests/ConversationPacksTests.swift`

**Interfaces — Produces:**
```swift
public protocol ConversationPackChecking: Sendable {
    func speechState(for locale: Locale) async -> PackState
    func translationState(from: Locale.Language, to: Locale.Language) async -> PackState
    func installSpeechPack(for locale: Locale) async throws
}
public enum ConversationPack: Equatable, Hashable, Sendable {
    case speech(ConversationSide)
    case translation(from: ConversationSide)
}
@MainActor @Observable public final class ConversationPacks {
    public enum Step: Equatable, Sendable {
        case checking
        case missing([ConversationPack])
        case installing(ConversationPack)
        case awaitingTranslationDownload(from: ConversationSide)
        case ready
        case failed(String)
    }
    public private(set) var step: Step
    public private(set) var isBusy: Bool
    public init(checking: any ConversationPackChecking)
    public func refresh() async
    public func download() async                     // 仅 missing：先装识别包（中、韩顺序），再逐个交给视图下载翻译包
    public func translationDownloadFinished(error: (any Error)?) async  // 仅 awaiting；每个包一次
    public func cancel()
}
```
`ModelReadiness` 在新文件里实现该协议（翻译状态走 `AppleTranslator.packState(from:to:)`）。任一包为 `unsupported` → `failed`。识别包安装失败（含保留名额超限）→ `failed`，文字用系统的错误说明，不释放任何保留。可读文案沿用 `UserMessages` 的风格。

- [ ] 写失败测试：`allInstalledIsReady`；`missingPacksAreListedInOrder`；`downloadInstallsSpeechThenAsksForEachTranslationPair`（zh→ko 与 ko→zh 两次 awaiting，之后 ready）；`anUnsupportedPackFails`；`anInstallErrorFailsWithItsMessage`；`aCancelledTranslationDownloadReturnsToMissing`；`reportsOutsideAwaitingAreIgnored`；`aDownloadThatDidNotInstallThePackFails`。
- [ ] 失败 → 实现 → 通过；提交 `feat(core): check and fetch the four face-to-face language packs`。

### Task 4: App 画面与入口

**Files:**
- Create: `MeetingTranslator/Features/FaceToFace/{FaceToFacePage,ConversationHalf,ConversationPacksView,ConversationTranslationDownload}.swift`
- Modify: `Presentation/AppRoute.swift`（及 `AppRouteTests.swift`）、`App/{RootView,AppAssembly,MeetingTranslatorApp}.swift`、`Features/LiveCaption/{LiveCaptionView,CaptionTopBar}.swift`、`Features/Onboarding/OnboardingPage.swift`

**Interfaces — Consumes:** Task 2、3 的类型。
**Produces:** `AppRoute.Page.faceToFace`；`public func showFaceToFace()`（记住来处）；`public func closeFaceToFace()`。

- [ ] 先写失败测试 `faceToFaceReturnsToWhereItCameFrom`（从 captions、从 onboarding 各一次）和 `faceToFaceIsNotOpenedWhileLaunching`；实现；通过。
- [ ] `AppAssembly`：面对面用自己的 `AudioCapture()`；两个翻译器 `AppleTranslator(target: side.other.translationLanguage)` 各建一次；`ModelReadiness` 复用同一实例。每次进入页面新建 `ConversationSession` 和 `ConversationPacks`。
- [ ] 画面：`ready` 之前显示缺哪些包和“下载”/“取消”/“重试”；`ready` 后上下两半，上半 `.rotationEffect(.degrees(180))`，按钮文字上半 `말하기`/`멈추기`，下半 `我说中文`/`结束`。每半列出全部条目、只用本方语言：本方说的显示 `original`（次要色），对方说的显示 `translation`（主色大字；`nil` 时 `翻译失败`/`번역 실패`）；说话方那一半显示 `liveText`；最新一条自动滚到底。`notice` 显示在说话方那一半（`没听清`/`잘 안 들렸어요`）。一方非 idle 时另一方按钮禁用。关闭按钮在下半。
- [ ] 页面：`.task` 里 `packs.refresh()`；`onDisappear` 里 `packs.cancel()` 并用独立 `Task` 调 `session.leave()`；`scenePhase` 只在 `.background`/`.active` 调 `enterBackground()`/`enterForeground()`；全程 `keepScreenAwake(true)`；按钮用独立 `Task` 调 `tap`。
- [ ] 翻译包下载修饰器照 `TranslationDownloadModifier` 的三条规则：配置由 step 推导、两次尝试之间置 nil、结果用独立 `Task` 恰好报告一次。语言对为 `from.translationLanguage → from.other.translationLanguage`。
- [ ] 入口：字幕页顶栏“面对面”按钮，仅会议 `idle`/`failed` 时可用；引导页同样的按钮。`#Preview` 覆盖缺包、两半有内容、在听三种。
- [ ] `xcodegen generate`，本地测试，推送 `feature/face-to-face`，CI 全绿；提交 `feat(app): add the face-to-face screen`。

### Task 5: 文档

**Files:** `README.md`、`docs/phase1-acceptance.md`、`docs/superpowers/notes/2026-11-21-engine-contracts.md`

- [ ] README 加一行功能说明；验收文档加“面对面”小节，照设计的“验收”一节，结果栏留空；真机清单加：开头几个字是否丢失、保留名额、`zh-CN` 识别与 `zh-Hans ↔ ko` 翻译下载、倒置半屏的滚动方向、来电与后台。不写任何未验证的结论。
- [ ] 提交 `docs: describe the face-to-face mode and its device checks`。
