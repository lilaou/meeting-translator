# Task 11c：引导页（计划草案）

范围：把 11b 里的"引导页占位"换成真实的 `OnboardingView`，并让 `RootView` 在引导完成后进入字幕页占位。字幕页本身是 11d。分支 `feature/task11c-onboarding`，从 `main`（5f31266）切出。

## 要达成的效果

英语一行，显示"识别包"和"翻译包"各自的状态；点"下载"依次装识别包、下载翻译包、跑自检；通过后显示"已就绪，可离线使用"和"开始"按钮；失败显示可读原因和"重试"。核心逻辑都在 11a 的 `OnboardingModel` 里，视图要做的是把它接上系统界面。

## 文件

- `MeetingTranslator/Features/Onboarding/OnboardingView.swift`：按 `onboarding.step` 渲染（见下表）。
- `MeetingTranslator/Features/Onboarding/TranslationDownloadModifier.swift`：把 `.translationTask` 接线单独放一个修饰器，因为它是整个任务里最脆弱的部分（须知 9 到 11），也是唯一使用 iOS 26 `Translation` 框架的视图代码。
- `MeetingTranslator/App/RootView.swift`：`step == .ready` 且用户点过"开始"才进字幕页占位，否则显示引导页。"开始"只是进入字幕页，会议在 11d 才真正启动。
- 不改核心包。若发现 `OnboardingModel` 的接口不够用，先停下来报告，不自行扩展。

## 各步骤的界面

| `step` | 显示 | 按钮 |
|---|---|---|
| `.checking` | 进度圈 + "正在检查语言包…" | 无 |
| `.needsSetup(speech, translation)` | 英语一行，识别包、翻译包状态；若两包都已安装（须知 12，即"再跑一次自检"）改显示"还需要完成一次自检" | "下载"（`isBusy` 时禁用） |
| `.installingSpeech` | 进度圈 + "正在安装识别包…" | "取消" |
| `.awaitingTranslationDownload` | 进度圈 + "正在下载翻译包…" | "取消" |
| `.selfTesting` | 进度圈 + "正在自检…" | "取消" |
| `.ready` | "已就绪，可离线使用" | "开始" |
| `.failed(message)` | 原因文字 | "重试"（`isBusy` 时禁用） |

状态文字：未安装、已安装、不支持。`PackState.unsupported` 已由核心包转成 `.failed`，视图不必另处理。

## 必须遵守的须知（来自契约文档）

- **须知 8：**视图出现时 `await onboarding.refresh()`（用 `.task`，它被取消时核心包会一并取消作业）；消失时 `onboarding.cancel()`。
- **须知 9、10、11：**`.translationTask` 的配置由 `step == .awaitingTranslationDownload` 推导：进入该状态时创建**新的** `TranslationSession.Configuration(source: onboarding.translationSource, target: onboarding.translationTarget)`，离开时置为 `nil`。动作里 `try await session.prepareTranslation()`，**恰好一次**调用 `translationDownloadFinished(error:)`（成功传 `nil`，失败传错误，被取消传 `CancellationError`）。语言对只能用 `translationSource` 和 `translationTarget`。
- **须知 12：**见上表。
- **`isBusy`：**为真时禁用"下载"和"重试"。
- **须知 3、4：**引导页不碰 SwiftData。
- 不新增任何网络代码；语言包下载由系统完成。

## 验收标准

1. CI 五个任务（三个包任务加两个 App 构建任务）全绿，Swift 编译器 0 警告（Xcode AppIntents 的两条提示除外）。
2. 本地 `swift test` 198 个测试仍然通过（核心包不变）。
3. 所有视图文件不超过 200 行；`#Preview` 为每个 `step` 提供假数据，保证预览能编译。
4. 评审逐条对照上面的须知，核对 `translationDownloadFinished` 在所有路径上恰好调用一次。

## 无法在本机验证的部分（记入真机清单）

- `prepareTranslation()` 被取消时是抛 `CancellationError` 还是别的错误，以及它在系统弹窗（下载确认）里的表现。
- 视图是否真的会在 `step` 回到 `.needsSetup` 后再次触发 `.translationTask`（须知 10 的"新配置"要求）。
- 飞行模式下点"下载"的表现（应是可读的失败，不卡住）。
- 本机 Xcode 16.4 编译不了 iOS 26 的视图，同 11b，只能靠 CI；视图的运行行为本任务内不验证。

## 流程

沿用 subagent 驱动流程：一个实现者（只许推送这一条分支，最多 4 次，只读的 `gh run` 看 CI）→ 我独立核对 → 一次评审（Opus）→ 修复循环 → 合并前问你。

## 需要你确认

1. 引导页文字是否接受上表的最简版。
2. 失败文字用核心包已有的可读中文原因，再加"重试"。
3. "开始"按钮只在自检通过后出现。
