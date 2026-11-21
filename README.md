# 离线会议字幕翻译（iPhone）

在 iPhone 上持续旁听会议，把外语实时识别并翻译成中文字幕，使用时不联网。

- 架构设计：`docs/superpowers/specs/2026-11-20-meeting-translator-design.md`
- 实施计划：`docs/superpowers/plans/2026-11-20-meeting-translator-phase0-1.md`
- 原始材料：`iphoneTranslator.md`（ChatGPT 的初步建议，架构部分已被上面的设计取代）

目前仓库里只有文档，还没有代码。开发必须在 Mac 上进行，本文件说明 Mac 上的准备步骤。

## 1. 拷贝项目

把整个项目目录拷到 Mac，例如 `~/Projects/iphoneTranslator`。计划和设计文档必须在一起，不要只拷计划文件。

目录还不是 git 仓库，计划的 Task 1 会执行 `git init`。

## 2. 检查系统与 Xcode

| 要求 | 检查命令 | 期望 |
|---|---|---|
| macOS 26 或更新 | `sw_vers -productVersion` | 主版本号 ≥ 26 |
| Xcode 带 iOS 27 SDK | `xcodebuild -showsdks \| grep iphoneos` | 出现 `iphoneos27` 开头的条目 |
| 命令行工具指向该 Xcode | `xcode-select -p` | 路径在 `Xcode.app` 内 |
| Swift 6 | `swift --version` | 主版本号 ≥ 6 |

macOS 版本的要求来自计划：核心逻辑包同时声明了 macOS 26，这样才能在 Mac 上直接跑 `swift test`。

`xcode-select -p` 指向别处时：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

首次安装 Xcode 后先打开一次，接受许可并等它装完附加组件。

## 3. 安装工具

```bash
# Homebrew（已有则跳过）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# XcodeGen：计划用它从 project.yml 生成工程
brew install xcodegen
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
用子代理逐任务的方式，从 Task 1 开始。
```

## 需要你亲自动手的环节

| 任务 | 你要做的事 | 大约耗时 |
|---|---|---|
| Task 1 | 在手机上操作验证程序、开飞行模式复测、让手机跑 120 分钟长时间测试、把结果填进 `docs/phase0-results.md` | 两个半小时，其中 120 分钟是等待 |
| Task 7、8 | 手机连着 Mac，跑真机测试 | 各几分钟 |
| Task 11 | 按计划里的 8 项验收表逐项操作 | 半小时到一小时 |

**Task 1 是闸门。** 真机验证不通过时计划要求停下来重新选方案，不要继续后面的任务。

## 已知的不确定之处

- 计划里的系统 API 名称来自 iOS 26 的文档，没有经过编译验证。iOS 27 SDK 上遇到对不上的地方，以官方文档为准修改，协议和测试不变。
- 切句长度上限、停顿时限、翻译积压阈值、上下文句数是暂定值，由 Phase 0 的实测数据校准。
- Apple 的"已支持""已安装"状态有不可靠的报告，所以设计要求下载后实际跑一次识别和翻译做离线自检。
