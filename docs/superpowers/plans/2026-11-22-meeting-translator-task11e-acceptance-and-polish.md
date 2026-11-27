# Task 11e：验收文档与工程收尾（计划草案）

范围：Phase 1 的最后一块。代码功能已在 11a 到 11d 完成；11e 不改核心包，不加新功能，只做验收文档、工程补全和 CI 加固。分支 `feature/task11e-acceptance`，从 `main`（6202579）切出。

## 现实前提（影响 11e 的写法）

- 真机验证需要一台 **Apple 芯片的 Mac**：Xcode 27 不能在 Intel 上运行，而 iPhone 运行 iOS 27.2，部署需要 Xcode 27（见对话中的调查；来自第三方文章，未直接核对 Apple 官方页面）。当前开发机是 Intel，所以 11e **不执行**真机验收，只把它写成可以直接照着做的文档。
- 所有 iOS 26/27 专用代码（引擎、App）只有 CI 能编译。11e 的新增内容同样由 CI 验证。
- 文档里**不得出现任何"已通过"的真机结论**：所有结果栏留空。

## 要做的事

### 1. `docs/phase1-acceptance.md`（核心）
- 开头列出**执行前提**：Apple 芯片 Mac（macOS 26.6 或更高）、Xcode 27.x、iPhone（iOS 27.x）已开启开发者模式、一个基准英语录音（`benchmark-en.wav` 加 `benchmark-en.txt`，见 `Packages/MeetingCore/Tests/MeetingCoreTests/Fixtures/README.md`，需用户自行提供且版权清晰）、`Local.xcconfig` 里填团队 ID。
- 原计划 Task 11 步骤 5 的**八项验收表**（全新安装联网引导、飞行模式重启直接进字幕页、飞行模式下十分钟基准录音、对照 Probe 的 final 文本无缺句、强杀后已定稿句子都在、来电时收尾并可重新开始、系统里删除英语识别资源后点开始、网络调试工具观察无任何请求），每项带"操作 / 预期 / 结果 / 日期 / 备注"，结果栏留空。
- 把 `docs/superpowers/notes/2026-11-21-engine-contracts.md` 的"真机验证清单"**按引用整合**（链接到各条，不复制，避免两份清单漂移），并列出验收时要顺手回答的**待定设计决定**：翻译收尾"无进展才超时"、规格第 160 行"会后可重试"、语音语言"保留"。
- 一节"运行包里的真机测试"：`RUN_DEVICE_TESTS=1` 和命令（见下面第 3 点）；明确写"未验证"。
- 一节"失败时怎么办"：按原计划 Step 6，用 systematic-debugging，在对应任务的测试里补一条能复现的用例，修复后重跑整张表。

### 2. App 图标与资源
- 新增 `MeetingTranslator/Resources/Assets.xcassets`（含 `AppIcon`，1024 像素单图）。图标是**我用本机的绘图脚本生成的原创占位图**（纯色底加"译"字），不使用任何第三方素材，你可以随时替换。
- `project.yml` 已预置 `ASSETCATALOG_COMPILER_APPICON_NAME`，只需把资源目录纳入 `sources`。不改显示名、Bundle ID。

### 3. 包测试在 iOS 上的编译检查（不引入应用内测试目标）
评审指出 App 的 scheme 没有可测试目标。原计划想"挂上包里的真机测试"，但在**无法运行**的前提下，新建应用承载的测试目标风险大于收益（需要签名、资源路径和 `@testable` 都无法验证）。所以 11e 的做法：
- CI 新增一步（放在一个 macOS 26 任务和一个 Xcode 27 任务里）：`xcodebuild build-for-testing -scheme MeetingCore -destination 'generic/platform=iOS Simulator'`，保证包的**测试代码也能为 iOS 编译**（现在只有 macOS 上编译过测试）。
- 文档里写出真机运行命令：`xcodebuild test -scheme MeetingCore -destination 'platform=iOS,name=<设备名>'`，环境变量 `RUN_DEVICE_TESTS=1`，并标注"未验证；若需要宿主应用再加测试目标"。
- 若 `build-for-testing` 在 CI 上失败且与测试本身的 macOS 专用写法有关，**先停下来报告**，不自行大改包的测试。

### 4. CI 加固（评审留下的两项）
- **固定 XcodeGen 版本**：不再 `brew install xcodegen`；改为下载固定版本（当前是 2.46.0）的官方发布压缩包并**校验 SHA-256**，校验值和来源链接写在工作流注释里。校验值必须取自官方发布页，取不到就保留 `brew` 并加 `HOMEBREW_NO_AUTO_UPDATE=1` 与 `xcodegen --version` 输出，并在报告里说明。
- **加一个 Release 构建**：在其中一个 App 任务里再 `-configuration Release` 构建一遍，覆盖只在优化构建里出现的警告（工程是警告当错误）。
- 其余三个包任务和权限、并发设置不动。

### 5. `README.md` 更新
README 里"检查系统与 Xcode"和"安装工具"一节是项目早期写的，现在已过时：要求 Xcode 带 iOS 27 SDK 却没说必须是 Apple 芯片，Homebrew 装不上 Intel。更新为：当前状态（Phase 1 代码完成，真机验收待做）、**Xcode 27 需要 Apple 芯片**、CI 是 iOS 26/27 代码的唯一编译器、本机（macOS 15 + Xcode 16.4）能做什么（核心包测试）、去哪里看验收文档。不放任何个人信息。

## 验收标准

1. CI 全部任务绿（三个包任务、两个 App 构建任务，加新增的 Release 构建和 `build-for-testing` 步骤），Swift 编译器 0 警告（Xcode AppIntents 的两条提示除外）；本地 `swift test` 198 个测试仍通过；核心包源码不改（测试目录不改，除非上面第 3 点触发停下报告）。
2. `docs/phase1-acceptance.md` 的八项都有"操作 / 预期"，**没有任何已通过的结论**；与契约文档的清单是引用关系，无重复条目。
3. 工程能 `xcodegen generate`，图标被识别；仓库里无 `.xcodeproj`、团队 ID、邮箱、第三方素材。
4. 所有文件不超过 200 行（文档除外）。

## 无法在本机验证的部分

图标是否在 iPhone 上正确显示、Release 构建的运行行为、`xcodebuild test` 在真机上的实际命令是否可用，都留给有 Apple 芯片 Mac 的真机阶段。

## 流程

一个实现者（只许推送这一条分支，最多 4 次，只读的 `gh run`）→ 我独立核对 → 一次评审（重点：文档里没有未验证的"已通过"，README 事实准确，CI 校验和来源可靠）→ 修复循环 → 合并前问你。

## 需要你确认

1. 图标用**我生成的占位图**（纯色加"译"字），以后你自己换，可以吗？
2. XcodeGen **固定版本并校验 SHA-256**，可以吗？
3. 包测试只加 `build-for-testing` 编译检查，**不新建应用内测试目标**，可以吗？
4. README 的更新范围（只改过时的环境说明和状态，不重写整份），可以吗？
