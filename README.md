# 离线会议字幕翻译（iPhone）

在 iPhone 上持续旁听会议，把外语实时识别并翻译成中文字幕，使用时不联网。

- 架构设计：`docs/superpowers/specs/2026-11-20-meeting-translator-design.md`
- 实施计划：`docs/superpowers/plans/2026-11-20-meeting-translator-phase0-1.md`
- 早期的方案笔记（ChatGPT 的初步建议）不在本仓库中；设计文档第 11 节记录了本设计与它的差异。

## 当前状态

- 源语言支持**英语（en-US）和韩语（ko-KR）**，译文都是简体中文。开会前在引导页顶部选择（选择会被记住），一场会议只用一种语言：没有自动识别，会议中不能切换。韩语是后加的（计划见 `docs/superpowers/plans/2026-11-27-korean-source-language.md`），只用假实现的单元测试和 CI 编译检查过，**没有在 iPhone 上验证过**。
- **面对面翻译（中文 ↔ 韩语）**：两个人共用一台 iPhone，各点自己的按钮说话，对话只显示文字（不朗读；文字会保存到历史记录），下半屏中文、倒置的上半屏韩语；从引导页或字幕页（会议未进行时）的"面对面"按钮进入。设计见 `docs/superpowers/specs/2026-11-27-face-to-face-design.md`。只用假实现的单元测试和 CI 编译检查过，**没有在 iPhone 上验证过**。
- **历史记录与导出**：会议和面对面对话的文字保存在手机上，在"历史记录"页（引导页底部或字幕页顶部进入，会议进行中不可进）查看、复制全文、导出为 .txt 或 .md 并经系统分享菜单分享、删除。记录**只存文字，不存录音**，会随系统的设备备份（iCloud 或电脑备份）一起备份。面对面对话里，已经识别出文字的那一句，即使还没翻译完就关闭页面，或还在听的时候切到后台，原话也会保存，标为"（未翻译）"；已知限制：这一句还没结束时 App 被系统杀掉，它仍会丢失。导出时生成的临时文件放在临时目录的一个专用文件夹里，App 启动时和从历史记录删除记录后整个删掉。手机上已装旧版本时，**升级前不要删除 App**（删除会连记录一起删掉），直接覆盖安装。2026-11-28 在一台 MacBook Air（macOS 26.6.1）上：App 编译通过，核心包 328 个测试通过；在 iOS 27 模拟器上，上一版本（提交 3865879）写的存储用新版本打开后会议和两句话完好，历史列表页和详情页能显示。**iPhone 上没有验证过**，分享出的文件名和手工删除流程也没有验证。加上之后的改动（保存被丢弃的发言、清理导出文件）后，同一台机器上模拟器版编译通过，核心包 334 个测试通过。计划见 `docs/superpowers/plans/2026-11-28-history-export.md`。
- 启动流程：启动时只对记住的语言做一次预检（只查两个语言包的状态，按设计只查本地状态，不做自检）。通过则直接进字幕页，否则进引导页。在字幕页点"更换语言"或"检查语言包"回到引导页后，要点"开始"才回到字幕页。这条启动路径没有在真机上验证过。
- Phase 1 的**代码已基本完成**：Task 2–4 和 Task 6–11 的代码已完成——核心包 `Packages/MeetingCore`（切句、翻译队列、会话协调、存储、Apple Speech / Translation 引擎、麦克风采集、引导流程的模型）和 App 目标 `MeetingTranslator`（引导页和实时字幕页，由 `project.yml` 经 XcodeGen 生成工程）。**Task 1（Probe 与 `docs/phase0-results.md`）以及依赖它的 Task 5（用 Phase 0 的真实片段回放校验切句、校准 `PipelineConfig`）都还没有做**，仓库里没有 Probe 工程和 Phase 0 结果。
- **真机验收尚未进行**。2026-11-27 首次在一台 iPhone 18 Pro Max（iOS 27.2）上试运行：能进到字幕页，识别出两句英语并给出中文译文，结束会议后字幕保留。这是联网状态下的一次非正式试用，不是验收：飞行模式、长时间运行等都没有测过。验收步骤、八项验收表、面对面翻译和历史记录的验收表（结果栏目前为空）见 `docs/phase1-acceptance.md`。
- 有两台开发机。一台是 Apple 芯片的 Mac（Xcode 27.2），能构建 App 并连真机；2026-11-27 在它上面核心包 205 个测试通过，App 的模拟器版和真机架构版编译通过（未签名）。另一台是 Intel Mac（macOS 15，Xcode 16.4）。在 Intel 这台上，Apple Speech / Translation 引擎的 iOS 26 部分用 `#if compiler(>=6.2)` 保护，在 Xcode 16.4 上会被跳过；App 目标使用 iOS 26 的 API（部署目标 26.0），需要 iOS 26 以上的 SDK，在这台机器上无法构建。**在 Intel Mac 上开发时，这部分代码由 CI 或 Apple 芯片的 Mac 编译**。
- 在 macOS 15 + Xcode 16.4 上能做的事：运行核心包的测试 `swift test --package-path Packages/MeetingCore`（用假实现，不涉及真机）。

## 1. 拷贝项目

项目是公开的 GitHub 仓库（lilaou/meeting-translator），在 Mac 上直接克隆：

```bash
git clone https://github.com/lilaou/meeting-translator.git
```

计划和设计文档都在仓库里。Apple 团队 ID 放在被 git 忽略的 `Local.xcconfig`（复制 `Local.xcconfig.example`），不要提交。

## 2. 检查系统与 Xcode

| 要求 | 检查命令 | 只开发/测试核心包 | Task 7–11（Apple 引擎、App、真机） |
|---|---|---|---|
| macOS | `sw_vers -productVersion` | 主版本号 ≥ 15 | 主版本号 ≥ 26（Apple 芯片） |
| Xcode | `xcodebuild -showsdks \| grep iphoneos` | Xcode 16.4 或更新 | Xcode 27，带 iOS 27 SDK，出现 `iphoneos27` 开头的条目 |
| 命令行工具指向该 Xcode | `xcode-select -p` | 路径在 `Xcode.app` 内 | 同左 |
| Swift 6 | `swift --version` | 主版本号 ≥ 6 | 同左 |

核心包 `Packages/MeetingCore` 声明的平台是 iOS 18 / macOS 15，所以只跑它的测试不需要 macOS 26；其中的 Apple 引擎用 `#if compiler(>=6.2)` 和可用性检查保护 iOS 26 的 API，App 目标的部署目标是 iOS 26.0。

**Task 7–11 和真机需要 Apple 芯片的 Mac。** 据 Apple 开发者论坛的帖子（<https://developer.apple.com/forums/thread/829619>）报道，Xcode 27 不能在 Intel Mac 上运行，且 iOS 27 的 iPhone 需要 Xcode 27 才能部署；这是帖子里的说法，没有对照 Apple 官方页面核实（审阅时也未能打开该帖子）。另据 Homebrew 的支持层级页面（<https://docs.brew.sh/Support-Tiers>）：Intel x86_64 macOS 是 Tier 3（可用但有警告、不再有新的预编译包），Homebrew 将在 2027 年 9 月或之后移除在 Intel 系统上运行的能力，macOS Tahoe 26 是最后一个能在 Intel 硬件上运行的 macOS。Intel Mac 因此只能做核心包的开发和测试。

`xcode-select -p` 指向别处时：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

首次安装 Xcode 后先打开一次，接受许可并等它装完附加组件。

## 3. 安装工具

```bash
# Homebrew（已有则跳过；曾在一台 Intel macOS 26 虚拟机上观察到安装脚本提示 "only supported on Apple Silicon processors"，仅一次观察，未核实；Intel 的支持情况见上文）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# XcodeGen：从 project.yml 生成工程（CI 固定使用 2.46.0，见 .github/workflows/ci.yml）
brew install xcodegen   # 装的是最新版，不是 CI 固定的 2.46.0
xcodegen --version
```

git 随 Xcode 命令行工具提供。确认已配置提交身份：

```bash
git config --global user.name
git config --global user.email
```

## 4. 安装 Claude Code 与 superpowers 插件

按官方文档安装 Claude Code：<https://code.claude.com/docs>

在项目目录启动 `claude`，然后安装插件：

```
/plugin install superpowers@claude-plugins-official
```

计划开头指定使用这个插件的执行技能。没装也能做，届时让 Claude 按计划逐任务执行即可。

## 5. 签名账号

Xcode → Settings → Accounts，登录 Apple ID。

| 账号 | 能否装到自己的手机 | 限制 |
|---|---|---|
| 免费 Apple ID | 能 | App 每 7 天过期，需重新安装 |
| 付费开发者账号 | 能 | 无此限制 |

两种都能完成本计划。

## 6. 准备 iPhone

1. 用数据线把 iPhone 18 Pro Max 连到 Mac，在手机上点"信任"。
2. 手机上打开：设置 → 隐私与安全性 → 开发者模式，按提示重启。
3. 确认 Mac 能看到设备：

   ```bash
   xcrun devicectl list devices
   ```

4. 确认手机系统为 iOS 27，并至少留出几 GB 的可用空间给系统语言包。
5. 手机保持联网。首次下载识别和翻译语言包需要网络，之后才能进飞行模式测试。

首次运行自己签名的 App 时，手机可能提示"不受信任的开发者"：设置 → 通用 → VPN 与设备管理，信任自己的开发者证书。

## 7. 准备测试录音

Phase 0 需要两类录音：

- **公开基准录音**：一段许可允许再分发的英语会议或讲座录音。执行 Task 1 时放到计划指定的位置，会进仓库。
- **自己的真实会议录音**：至少一段，放在项目根目录的 `recordings/` 下。这个目录会被 git 忽略，不进仓库。

## 8. 开始执行

在项目目录启动 Claude Code，输入：

```
按 docs/superpowers/plans/2026-11-20-meeting-translator-phase0-1.md 执行，
用子代理逐任务的方式，从 Task 1 的 Probe 步骤开始，然后做 Task 5（Task 2–4 和 6–11 的代码已完成；Task 11 只剩真机验收，见 docs/phase1-acceptance.md）。
```

后续引擎任务要遵守的约定和未决事项见 `docs/superpowers/notes/2026-11-21-engine-contracts.md`。

## 需要你亲自动手的环节

| 任务 | 你要做的事 | 大约耗时 |
|---|---|---|
| Task 1 | 在手机上操作验证程序、开飞行模式复测、让手机跑 120 分钟长时间测试、把结果填进 `docs/phase0-results.md` | 两个半小时，其中 120 分钟是等待 |
| Task 7、8 | 手机连着 Mac，跑真机测试 | 各几分钟 |
| Task 11 | 按 `docs/phase1-acceptance.md` 的 8 项验收表逐项操作并填写结果 | 半小时到一小时 |

**Task 1 是闸门。** 真机验证不通过时计划要求停下来重新选方案，不要继续后面的任务。

## 已知的不确定之处

- 计划里的系统 API 名称来自 iOS 26 的文档，没有经过编译验证。iOS 27 SDK 上遇到对不上的地方，以官方文档为准修改，协议和测试不变。
- 切句长度上限、停顿时限、翻译积压阈值、上下文句数是暂定值，由 Phase 0 的实测数据校准。
- Apple 的"已支持""已安装"状态有不可靠的报告，所以设计要求下载后实际跑一次识别和翻译做离线自检。

## CI 与许可证

- CI 用 GitHub Actions（`.github/workflows/ci.yml`）：在 `macos-26` 上跑核心包测试和 iOS 模拟器编译，在 `xcode-27` 上用 iOS 27 SDK 再测一遍。只用标准 runner，公开仓库免费；不要改成 `-large` / `-xlarge`，大号 runner 会计费。CI 还会用 XcodeGen 生成工程并为 iOS 模拟器构建 App（含一次 Release 构建），并对包的测试代码做 `build-for-testing`（只编译、不运行）。XcodeGen 固定为 2.46.0 并校验 SHA-256。CI 只能验证编译和用假实现的单元测试，麦克风、系统语言包和飞行模式验收仍需真机。
- 许可证：MIT，见 `LICENSE`。
