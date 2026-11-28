# 历史记录与导出/分享 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每场会议和每次面对面对话的文字都保存在手机上，可以查看、复制、导出（txt / md）、分享、删除。

**Architecture:** 会议文字已经由 `TranscriptStore` 保存；在 `SchemaV2` 里**只新增**两个面对面对话的实体（轻量迁移）。导出文本由 MeetingCore 里的纯函数生成并测试；App 层新增"历史记录"页（`AppRoute.history`），只用 `@Query` 读，写和删都经过 `TranscriptStore`。

**Tech Stack:** Swift 6、SwiftData、SwiftUI（`ShareLink`、`Transferable`）、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-11-20-meeting-translator-design.md`（5.7、5.8 第 3 项）。用户 2026-11-28 追加：面对面对话也要保存（推翻 `2026-11-27-face-to-face-design.md` 里"对话不保存到手机"），并提供导出/分享和删除。用户要求直接开工，设计决定记在本计划里。

## Global Constraints

- 已有会议记录不能丢失；`Meeting`、`Segment` 的存储属性和关系**一个都不改**。
- `TranscriptStore` 是唯一写入者；界面只用 `@Query` 读，不在 `mainContext` 上增删改存。
- App 不含任何网络代码；导出/分享只走系统分享菜单和剪贴板，由用户点击触发。
- 只存文字，不存录音。
- 界面文字用简体中文。
- 会议进行中不能进入历史记录页（和"面对面"按钮同样的条件）。
- 核心包测试：`cd Packages/MeetingCore && swift test`（本机 macOS 15，Swift 6.1）。App 目标和 `#if compiler(>=6.2)` 的代码本机编译不了；Swift 6.3 拒绝在跳到 @MainActor 的非隔离闭包里用 `[weak self]`。
- 提交信息结尾：`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` 和 `Claude-Session: https://claude.ai/code/session_01A4t3X6uy1PL6VNA6nKj1ro`。

## Review Focus

- 用 V1 建的、磁盘上已有会议的存储，用 V2 打开后记录完好（Task 1）。
- 删掉字幕页上刚结束的那场会议后回到字幕页：空列表，不崩溃；之后能正常开新会议（Task 1 测存储，Task 4 手工核对）。
- 对话保存失败（磁盘满等）：对话照常进行，屏幕上提示没有保存（Task 2）。
- 会议中途被杀（`endedAt == nil`）的记录仍能列出、导出（Task 3）。
- 译文缺失（待翻译、失败、中断标记）在导出里有明确文字，不是空行或丢句（Task 3）。

---

### Task 1: 存储 — SchemaV2、对话实体、删除

**Files:**
- Modify: `Packages/MeetingCore/Sources/MeetingCore/Storage/{Models.swift,MeetingSchema.swift,TranscriptStore.swift}`
- Test: `Packages/MeetingCore/Tests/MeetingCoreTests/HistoryStoreTests.swift`

**Interfaces — Produces:**

```swift
@Model public final class ConversationRecord {
    public var id: UUID; public var startedAt: Date; public var languageCodes: [String]
    @Relationship(deleteRule: .cascade, inverse: \ConversationTurnRecord.conversation)
    public var turns: [ConversationTurnRecord]
}
@Model public final class ConversationTurnRecord {
    public var id: UUID; public var conversation: ConversationRecord?
    public var index: Int; public var speakerCode: String   // ConversationSide.rawValue
    public var original: String; public var translation: String?; public var date: Date
}
// TranscriptStore
func startConversation(languageCodes: [String], at: Date) throws -> UUID
func appendTurn(speakerCode: String, original: String, translation: String?, at: Date, to: UUID) throws -> UUID
func turns(of conversationID: UUID) throws -> [ConversationTurnRecord]   // by index
func deleteMeeting(_ id: UUID) throws          // cascades segments
func deleteConversation(_ id: UUID) throws     // cascades turns
// StoreError gains .conversationNotFound(UUID)
```

`SchemaV2` = 2.0.0，models 是 V1 的两个类加两个新类；`MeetingMigrationPlan` 的 schemas 为 `[V1, V2]`，stages 为一个 `.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)`；`MeetingStorage.schema` 指向 V2。更新这两个文件里相应的注释。

- [ ] **Step 1: 写失败的测试** — `v1StoreOpensUnderV2WithItsMeetingsIntact`（用 `Schema(versionedSchema: SchemaV1.self)` 直接在临时目录建磁盘存储，写一场两句的会议，释放容器，再用 `MeetingStorage.makeContainer(at:)` 打开：标题、句子、译文、顺序不变，且可以写入对话）；`appendTurnKeepsOrderAndSurvivesAFreshContext`；`deleteMeetingRemovesItsSegmentsOnly`；`deleteConversationRemovesItsTurnsOnly`；`deletingUnknownIDThrows`；`failedDeleteIsRolledBack`（用 `failNextSaves`）；`translationForADeletedSegmentThrowsSegmentNotFound`。
- [ ] **Step 2:** `swift test --filter HistoryStore`，预期编译失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `swift test`，预期全部通过。若 V1/V2 共用类导致迁移测试失败，按 `MeetingSchema.swift` 注释把 V1 形状冻结为嵌套副本，并在报告里说明。
- [ ] **Step 5: 提交** `feat(core): store face-to-face conversations and delete records`

### Task 2: 面对面对话边说边保存

**Files:**
- Create: `Packages/MeetingCore/Sources/MeetingCore/Conversation/ConversationRecorder.swift`
- Modify: `Conversation/ConversationSession.swift`, `Conversation/ConversationSession+Turn.swift`
- Test: `Packages/MeetingCore/Tests/MeetingCoreTests/ConversationRecorderTests.swift`

**Interfaces — Consumes:** Task 1 的 store 方法。**Produces:**

```swift
@MainActor public protocol ConversationSaving: AnyObject {
    func save(speaker: ConversationSide, original: String, translation: String?) throws
}
@MainActor public final class ConversationRecorder: ConversationSaving {
    public init(store: TranscriptStore, now: @escaping () -> Date = { Date() })
}
// ConversationSession.init 增加最后一个参数 saver: (any ConversationSaving)? = nil
public internal(set) var saveFailed: Bool   // 最近一次保存失败；下一轮开始时清掉
```

行为：第一次成功识别出一轮时才建记录（空访问不留记录），语言代码 `["zh", "ko"]`；一次访问一条记录。只有进入 `utterances` 的轮次才保存（被丢弃的轮次不保存）。翻译失败的轮次保存原文、`translation = nil`。保存失败不影响对话。`leave()` 只清屏幕，不删记录。更新 session 注释里的 "Nothing is stored"。

- [ ] **Step 1: 写失败的测试** — `eachFinishedTurnIsStoredInOneRecord`、`visitWithoutTextStoresNothing`、`failedTranslationStoresTheOriginal`、`discardedTurnIsNotStored`、`saveFailureKeepsTheUtteranceAndSetsSaveFailed`、`nextTurnClearsSaveFailed`、`leaveKeepsTheStoredRecord`。复用 `ConversationFakes.swift`。
- [ ] **Step 2:** `swift test --filter ConversationRecorder`，预期失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `swift test` 全过。
- [ ] **Step 5: 提交** `feat(core): save face-to-face turns as they finish`

### Task 3: 导出文本与历史条目

**Files:**
- Create: `Packages/MeetingCore/Sources/MeetingCore/Presentation/{TranscriptDocument.swift,TranscriptExport.swift}`
- Modify: `Presentation/AppRoute.swift`
- Test: `Tests/MeetingCoreTests/TranscriptExportTests.swift`, `AppRouteTests.swift`

**Interfaces — Produces:**

```swift
public enum ExportFormat: String, CaseIterable, Sendable { case text, markdown   // 扩展名 txt / md
    public var fileExtension: String }
public struct TranscriptDocument: Equatable, Sendable {
    public enum Kind: Sendable { case meeting, conversation }
    public struct Entry: Equatable, Sendable { public let label: String; public let original: String; public let translation: String }
    public let kind: Kind; public let title: String; public let startedAt: Date
    public let metadata: [String]; public let entries: [Entry]
    @MainActor public init(meeting: Meeting, timeZone: TimeZone = .current)
    @MainActor public init(conversation: ConversationRecord, timeZone: TimeZone = .current)
    public var preview: String   // 第一条的译文，译文是占位文字时用原文；无条目为 ""
}
public enum TranscriptExport {
    public static func render(_ document: TranscriptDocument, as: ExportFormat) -> String
    public static func fileName(for document: TranscriptDocument, as: ExportFormat, timeZone: TimeZone = .current) -> String
}
// AppRoute.Page 增加 .history；showHistory() / closeHistory()，规则同 showFaceToFace/closeFaceToFace
```

固定内容：
- title：会议 `会议记录 2026-11-28 14:30`，对话 `面对面对话 2026-11-28 14:30`。
- metadata：会议 `语言：英语 → 中文`，有 `endedAt` 时加 `时长：00:42:17`；对话 `语言：中文 ↔ 韩语`。
- 会议条目 label 是相对时间 `00:00:05`，按 `index` 排序；中断标记条目 original 为 `（录音中断）`、translation 为 `""`。对话条目 label 是 `14:31:02 中文方` / `韩语方`。
- 缺译文：待翻译 `（未翻译）`，失败 `（翻译失败）`；对话的 `nil` 为 `（翻译失败）`。
- 文件名：`会议-20261128-1430.txt`、`对话-20261128-1430.md`。
- 纯文本：title 行、metadata 各一行、空行；每条为 `[label]`、original、translation（空则省略），条目间空一行；结尾一个换行。
- Markdown：`# title`、空行、metadata 为 `- ` 列表、空行；每条 `**label**`、空行、`> original`、空行、translation。原文里的换行在引用中逐行加 `> `。

- [ ] **Step 1: 写失败的测试** — `meetingTextExportMatchesExactly`、`meetingMarkdownExportMatchesExactly`、`conversationExportShowsSpeakersAndClockTimes`、`unfinishedMeetingHasNoDurationButAllSentences`、`missingTranslationsAreNamed`、`fileNamesCarryKindAndTime`、`previewFallsBackToTheOriginal`、`historyOpensFromCaptionsAndReturnsThere`、`historyIsIgnoredWhileLaunching`。导出测试用固定时区 `Asia/Shanghai` 和完整字符串比较。
- [ ] **Step 2:** `swift test --filter "TranscriptExport|AppRoute"`，预期失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4:** `swift test` 全过。
- [ ] **Step 5: 提交** `feat(core): render transcripts for export and route to history`

### Task 4: 历史记录界面与接线

**Files:**
- Create: `MeetingTranslator/Features/History/{HistoryPage.swift,TranscriptDetailView.swift,TranscriptFile.swift}`
- Modify: `App/{AppAssembly.swift,RootView.swift,MeetingTranslatorApp.swift}`, `Features/LiveCaption/{LiveCaptionView.swift,CaptionTopBar.swift}`, `Features/Onboarding/OnboardingPage.swift`, `Features/FaceToFace/{FaceToFacePage.swift,ConversationHalf.swift}`

**Interfaces — Consumes:** Task 1–3 的全部公开接口。

内容：
- `HistoryPage`：`NavigationStack`，标题"历史记录"，左上"关闭"。两个 `@Query`（会议、对话）合并按时间倒序；每行显示类型（会议/对话）、时间、`preview`。没有任何句子的记录不列出。空状态："还没有记录"。左滑删除，删除前弹确认："删除这条记录？删除后无法恢复。"。
- `TranscriptDetailView`：条目列表（label 小字、原文、译文大字，可长按选择文字）；工具栏菜单："分享文本文件"、"分享 Markdown 文件"（`ShareLink` + `TranscriptFile: Transferable`，文件名用 `TranscriptExport.fileName`）、"复制全文"（纯文本到 `UIPasteboard`）、"删除"（同样确认，删后返回列表）。删除失败弹提示"删除失败"。
- 删除后详情页不得再读已删除的模型对象（详情页持有 `TranscriptDocument` 值或用 `@Query` 按 id 查）。
- 入口：字幕页顶部"历史"按钮，禁用条件同"面对面"；引导页在"面对面"旁边加"历史记录"。顶部栏已经拥挤：保证长语言名下按钮不被截断（必要时用图标按钮并加无障碍标签"历史记录"）。
- `AppAssembly`：`TranscriptStore` 只建一个，协调器、历史页删除、`ConversationRecorder`（每次访问一个，在 `makeVisit` 里）共用。
- 面对面页：`saveFailed` 时显示"这条对话没有保存"。
- 每个新视图带 `#Preview`（样例数据）。

- [ ] **Step 1: 实现。**
- [ ] **Step 2:** `cd Packages/MeetingCore && swift test` 全过。App 目标本机编译不了：在报告里写明，由控制者在 MacBook Air 上 `xcodegen generate` 后用模拟器编译、截图核对。
- [ ] **Step 3: 提交** `feat(app): browse, export, share and delete transcripts`

### Task 5: 文档

**Files:** Modify `docs/superpowers/specs/{2026-11-20-meeting-translator-design.md,2026-11-27-face-to-face-design.md}`, `docs/superpowers/notes/2026-11-21-engine-contracts.md`, `docs/phase1-acceptance.md`, `README.md`

- [ ] **Step 1:** 面对面设计里把"对话不保存"标注为已被 2026-11-28 的用户决定替代；主设计 5.7 加两个对话实体、5.8 第 3 项写明现状。验收文档加历史记录行 H1–H6（结果栏留空）：列出旧会议；面对面对话出现在列表；分享 txt 和 md 到"文件"后打开核对；复制全文；删除后重启仍不在；删除字幕页刚结束的会议后返回不崩溃。README 功能列表加历史与导出，并写明记录只存文字、会随系统的设备备份一起备份。契约文档记录：store 是唯一写入者的规则现在包含删除和对话。
- [ ] **Step 2: 提交** `docs: describe history, export and the stored conversations`
