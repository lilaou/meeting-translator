# Task 11d：字幕页（计划草案）

范围：把 11c 里的"字幕页占位"换成真实的 `LiveCaptionView`。会议能在 App 里真正开始、实时显示字幕、结束。真机验收和文档是 11e。分支 `feature/task11d-caption-view`，从 `main`（9bbf272）切出。

## 要达成的效果

顶栏显示"英语 → 中文"、已用时间、"离线"标签，翻译滞后时再显示"翻译滞后"。中间是字幕列表：每行原文小字在上、译文大字在下，末尾一行是临时识别（次要颜色）。底部是"开始会议"或"结束会议"。新内容自动滚到底；用户上翻后停止跟随，出现"回到最新"。听写期间屏幕常亮。

## 数据来源（核心包已就绪，11d 不改核心包）

- 协调器 `SessionCoordinator`（环境里已有）：`state`（`idle`、`preparing`、`listening`、`finishing`、`failed(String)`）、`volatileText`、`isTranslationLagging`、`meetingID`、`startedAt`、`start(locale:)`、`finish()`。
- 列表：`@Query` 读 `Segment`，按 `index` 排序，按 `meeting?.id == meetingID` 过滤。
- 行的展示：`SegmentDisplay(segment)` 已处理四种状态（已译、待译"…"、"（翻译失败）"、"（录音中断）"）。
- 文案和格式：`CaptionStrings`、`CaptionFormatting.elapsedText`、`ScrollFollowState`。

## 文件

- `MeetingTranslator/Features/LiveCaption/LiveCaptionView.swift`：整体布局、读环境里的协调器、开始/结束动作。
- `MeetingTranslator/Features/LiveCaption/CaptionListView.swift`：子视图，`init(meetingID:)` 构造 `@Query`（须知 5）；滚动跟随；末尾的临时行。
- `MeetingTranslator/Features/LiveCaption/CaptionTopBar.swift`：顶栏。用 `TimelineView(.periodic)` 提供不断更新的 `now`（须知 14）。
- `MeetingTranslator/Features/LiveCaption/SegmentRow.swift`：一行；三种状态加"录音中断"。
- `MeetingTranslator/App/RootView.swift`：`started` 为真时显示 `LiveCaptionView`；字幕页在失败时可回到引导页（见下）。
- 不改核心包；接口不够用时先停下来报告。

## 底部按钮与各状态

| `state` | 显示 | 按钮 |
|---|---|---|
| `idle` | 空列表或上一场的记录 | "开始会议" |
| `preparing` | 转圈 + "正在准备…" | 禁用 |
| `listening` | 字幕 + 临时行 | "结束会议" |
| `finishing` | 转圈 + "正在整理收尾…"（可能约 40 秒，须知 6） | 禁用 |
| `failed(message)` | 原因文字（可能含"；"连接的多条，逐条换行显示）；已存字幕保留可见 | "重新开始"和"检查语言包" |

- "开始会议"调用 `coordinator.start(locale: AppAssembly.sourceLocale)`；预检由协调器自己完成，失败就进入 `failed` 并显示可读原因，字幕页不另做检查（上一轮评审提醒从后台回来后"已就绪"可能过期，这样处理即可）。
- "检查语言包"（我自己加的小范围扩展，供你否决）：让 `RootView` 把 `started` 置回 `false`，回到引导页重新检查，因为"语言包被系统回收"这种失败在字幕页里用户无法自己解决。
- `start` 在 `.idle`/`.failed` 以外会被忽略，按钮在其他状态下一律禁用。

## 必须遵守的须知（来自契约文档）

- **3、4：**视图只用 `@Query` 读，**绝不**在 `mainContext` 上插入、修改、删除或保存，也不用 `@Bindable` 编辑。`@Model` 对象只在主 actor 上用。预览造数据只能在 `#if DEBUG` 的预览辅助里、对内存容器做，并在注释里写明这不是产品代码。
- **5：**列表子视图的 `init(meetingID:)` 构造按 `meeting?.id` 过滤、按 `index` 排序的 `Query`。
- **6：**`finishing` 要显示并禁用按钮；`failed(message)` 要显示原文，可能多条用"；"连接。
- **13：**只有用户自己的滚动（`onScrollPhaseChange` 里 interacting 或 decelerating 阶段）才调用 `ScrollFollowState.userScrolled`，并在底部留容差；内容增长和程序触发的滚动不算。
- **14：**已用时间用 `TimelineView` 的 `now` 加 `coordinator.startedAt`；`startedAt` 为空时不显示时间。
- **17：**`listening`（含 `preparing`、`finishing`）期间 `isIdleTimerDisabled = true`，离开字幕页或回到 `idle`/`failed` 时恢复；视图消失也要恢复。
- 不加任何网络代码。

## 验收标准

1. CI 五个任务全绿，Swift 编译器 0 警告（Xcode AppIntents 的两条提示除外）；本地 `swift test` 198 个测试仍通过。
2. 所有文件不超过 200 行；`#Preview` 覆盖：空列表、三种行状态加录音中断、临时行、翻译滞后、`finishing`、`failed`（两条原因）。
3. 评审逐条对照上面的须知，并推演：开始 → 结束 → 再开始（列表是否切到新会议）、`failed` 后的字幕仍可见、滚动跟随在新内容到达时不被程序滚动误关、屏幕常亮在所有退出路径上都恢复。

## 无法在本机验证的部分（记入真机清单）

- `@Query` 在真实 SwiftUI 场景里是否实时更新（清单里已有）。
- 滚动跟随的阶段判定（`onScrollPhaseChange`）在 iOS 26/27 上的实际表现，和长会议（几千行）下的滚动性能。
- 字幕页与引导页之间的切换，以及后台切回后的表现。

## 流程

一个实现者（只许推这一条分支，最多 4 次，只读的 `gh run`；核心包不许改）→ 我独立核对 → 一次评审（Opus，逐条推演）→ 修复循环 → 合并前问你。

## 需要你确认

1. `finishing` 显示"正在整理收尾…"加转圈、按钮禁用。
2. 失败后除"重新开始"外，再加一个"检查语言包"回到引导页。
3. 开始会议前不另做检查，由协调器预检并报告。
