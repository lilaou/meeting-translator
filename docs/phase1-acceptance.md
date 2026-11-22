# Phase 1 真机验收

状态：**未验证**。到目前为止没有在任何真机上运行过本项目；下面所有"结果"和"日期"栏都是空的，由执行验收的人亲自填写。CI 只能证明代码能编译、核心包的假实现单元测试能运行，不能代替这里的任何一项。

## 1. 执行前提

- **Apple 芯片的 Mac**，macOS 26.6 或更高，装有 Xcode 27.x。据第三方文章和 Apple 开发者论坛的帖子（<https://developer.apple.com/forums/thread/829619>）报道，Xcode 27 不能在 Intel Mac 上运行；这一点**没有**对照 Apple 官方页面核实，执行前请自行确认。运行 iOS 27 的 iPhone 需要 Xcode 27 才能部署。另据 Homebrew 的支持层级说明（<https://docs.brew.sh/Support-Tiers>）报道，其安装脚本拒绝在 Intel Mac 上安装；同样未经核实。当前的开发机是 Intel（macOS 15，Xcode 16.4），所以只能跑核心包的测试，还没有任何真机验收。
- iPhone 运行 iOS 27.x，已开启开发者模式（设置 → 隐私与安全性 → 开发者模式），用数据线连到 Mac 并信任。
- 复制 `Local.xcconfig.example` 为 `Local.xcconfig`（已被 git 忽略），填入自己的团队 ID。不要提交这个文件。
- 在项目根目录运行 `xcodegen generate` 生成工程（`.xcodeproj` 不进仓库），用 Xcode 选择真机运行 `MeetingTranslator`。
- 手机首次需要联网下载英语识别和翻译语言包，之后才能进入飞行模式。
- 一段基准英语录音：`benchmark-en.wav` 加 `benchmark-en.txt`。**这两个文件不在仓库里**，需要你自行提供，并且许可必须允许再分发（仓库是公开的）。格式和放置位置见 `Packages/MeetingCore/Tests/MeetingCoreTests/Fixtures/README.md`。第 3、4 项用另一台设备播放这段录音；私人会议录音放在被忽略的 `recordings/` 目录，不要放进 Fixtures。

## 2. 八项验收表

来自计划 `docs/superpowers/plans/2026-11-20-meeting-translator-phase0-1.md` 的 Task 11 步骤 5。"结果""日期""备注"栏留空，由执行者填写。

| # | 操作 | 预期 | 结果 | 日期 | 备注 |
|---|---|---|---|---|---|
| 1 | 全新安装，联网完成引导 | 显示"已就绪，可离线使用" | | | |
| 2 | 开飞行模式，杀掉并重启 App | 直接进入字幕页 | | | |
| 3 | 飞行模式下开始会议，用另一台设备播放基准录音 10 分钟 | 原文实时出现；每句定稿后出现中文；已显示的译文不变化 | | | |
| 4 | 对照 Probe 日志里同一段录音的 final 文本 | 没有缺句 | | | |
| 5 | 会议中强杀 App，重启后用 Xcode 查看数据容器或临时加日志 | 强杀前已定稿的句子都在 | | | |
| 6 | 会议中给手机打电话 | 会议收尾，状态回到可重新开始，记录完整 | | | |
| 7 | 在系统设置里删除英语识别资源后点"开始会议" | 显示可读的错误提示，不崩溃 | | | |
| 8 | 用 Xcode 的网络调试工具观察一场会议 | App 无任何网络请求 | | | |

第 4 项需要 Phase 0 的 Probe 日志。如果当时没有保存，需要先用 Probe 对同一段录音重新跑一遍。

## 3. 顺手核对的清单与待定决定

契约文档 `docs/superpowers/notes/2026-11-21-engine-contracts.md` 维护两份清单，验收时一并处理。这里只引用，不复制条目，以免两份清单不一致：

- 「真机验证清单（需要真机）」：该节的每一条都要在真机上确认，包括 11d 字幕页的各子项和标注"有条件"的那一条。
- 「待定的设计决定」：该节目前列出翻译收尾的超时策略。

验收时要顺手回答三个尚未决定的问题，答案写进"备注"或另开记录：

1. **翻译收尾的超时**：`translationDrainTimeout` 是否应改成"没有进展才超时"，并让界面显示"正在完成翻译…"（契约文档「待定的设计决定」）。
2. **会后可重试**：设计规格（`docs/superpowers/specs/2026-11-20-meeting-translator-design.md`）第 160 行写"翻译失败的句子保留原文，会后可重试"，但 Phase 1 没有重试，被放弃的句子的译文不会再补上。要么实现重试，要么改规格。
3. **语言区域的预留（reserve）**：当系统早已装有识别模型、引导流程从不调用 `installSpeechPack` 时，语言区域从未被预留，自检可能一直失败（契约文档「真机验证清单」中标注"有条件"的那一条）。需要真机上确认并决定补救方式。

## 4. 运行包里的真机测试

未验证。包里的真机测试默认跳过，环境变量 `RUN_DEVICE_TESTS=1` 才会运行：

```bash
cd Packages/MeetingCore
RUN_DEVICE_TESTS=1 xcodebuild test -scheme MeetingCore \
  -destination 'platform=iOS,name=<设备名>'
```

注意：

- 这条命令本身没有在真机上试过，环境变量能否传到设备上的测试进程、是否需要先在 scheme 里设置，都要实际确认。仓库里没有应用承载的测试目标；如果测试需要宿主应用，再加测试目标。
- CI 只做 `build-for-testing`（编译包的测试代码给 iOS 模拟器），不运行它们。
- `AppleSpeechEngineDeviceTests` 需要基准录音 `benchmark-en.wav` 和 `benchmark-en.txt`。它们**不在仓库里**，需要用户自行提供，且许可必须清楚地允许再分发；缺失时测试会跳过并说明缺哪个文件。详见 `Packages/MeetingCore/Tests/MeetingCoreTests/Fixtures/README.md`。
- 设备上还需要已安装英语语音资源（iOS 26 或更高）。

## 5. 失败时怎么办

任何一项不符合预期：

1. 用 `superpowers:systematic-debugging` 先找到根本原因，不要凭猜测改代码。
2. 在对应任务的测试里补一条能复现它的用例（先看到它失败），再修复。
3. 修复后**重跑整张表**，不只重跑失败的那一项。
