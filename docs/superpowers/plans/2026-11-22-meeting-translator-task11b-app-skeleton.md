# Task 11b：App 工程骨架与 CI 构建（计划草案）

范围：只做能被 CI 编译通过的 App 骨架，不含界面细节。引导页和字幕页分别是 11c、11d；真机验收和文档是 11e。分支 `feature/task11b-app-skeleton`，从 `main`（75f77ef）切出。

## 已确定的决定

| 项目 | 取值 |
|---|---|
| Bundle ID | `io.github.lilaou.MeetingTranslator`（原计划的 `com.local.…` 作废） |
| 显示名 | 会议字幕（`CFBundleDisplayName`） |
| 部署目标 | iOS 26.0；Swift 6 语言模式 |
| 签名 | 团队 ID 只放在未提交的 `Local.xcconfig`；提交 `Local.xcconfig.example` |
| 生成的工程 | 不提交 `.xcodeproj`，由 XcodeGen 生成，加入 `.gitignore` |

## 文件

- `project.yml`：App 目标 `MeetingTranslator`，依赖本地包 `Packages/MeetingCore`，`#include? "Local.xcconfig"`，Swift 6、严格并发 complete，`SWIFT_TREAT_WARNINGS_AS_ERRORS` 开启。
- `MeetingTranslator/App/Info.plist`：`NSMicrophoneUsageDescription`（"用于识别会议语音，音频不会离开本机"）、`UIBackgroundModes: [audio]`、横竖屏、`ITSAppUsesNonExemptEncryption = false`。不加任何网络相关键。
- `MeetingTranslator/App/MeetingTranslatorApp.swift`：App 入口，只做装配并交给根视图。
- `MeetingTranslator/App/AppAssembly.swift`：`@MainActor` 的装配函数，用 `MeetingStorage.makeContainer(at:)` 建磁盘容器，装配真实的 `AppleSpeechEngine`、`AppleTranslator`、`AudioCapture`、`ModelReadiness`、`TranscriptStore`、`SessionCoordinator`、`OnboardingModel`。容器创建失败时不崩溃，进入一个可读的错误页。
- `MeetingTranslator/App/RootView.swift`：占位根视图，按 `OnboardingModel` 状态在两个占位页之间切换（"引导页占位"、"字幕页占位"），真实视图由 11c、11d 替换。
- `.gitignore`、`Local.xcconfig.example`。
- `.github/workflows/ci.yml`：新增两个任务 `build-app-macos-26`、`build-app-xcode-27`，内容为安装 XcodeGen、`xcodegen generate`、`xcodebuild build -scheme MeetingTranslator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`。

## 验收标准

1. 两个新 CI 任务在 Xcode 26.6 和 Xcode 27.1 上都通过，0 警告。
2. 原有三个包任务仍然全绿，本地 `swift test` 198 个测试通过。
3. 仓库里没有 `.xcodeproj`、没有团队 ID、没有邮箱。
4. Info.plist 的键与上表一致；源文件不超过 200 行。
5. 装配代码里没有任何网络调用；包内公开接口不变。

## 已知风险（由 CI 验证）

- 本机 Xcode 16.4 无法编译 iOS 26 部署目标，所以 App 只能靠 CI 编译，和核心包的做法一致。
- `xcode-27` 运行镜像上能否用 Homebrew 安装 XcodeGen 未验证；备选：固定版本的 release 压缩包下载并校验 SHA-256。
- 装配里的初始化参数以代码里的实际签名为准（`SessionCoordinator.init` 在 `Pipeline/SessionCoordinator.swift:56`）。

## 流程

沿用 subagent 驱动流程：一个实现者 + 独立复核 + 评审 + 修复循环。因为 CI 是唯一的验证者，实现者只许推送这一条功能分支（最多 4 次），并用只读的 `gh run` 命令查看结果。11b 完成合并后再起草 11c。

## 不在本任务里

引导页和字幕页的真实视图、`.translationTask` 接入、真机测试目标、`docs/phase1-acceptance.md`；`NOTES` 里 Task 11 的 17 条须知在 11c、11d 才会用到，11b 只遵守与装配相关的几条（容器创建、单一协调器、`translationSource/Target`）。
