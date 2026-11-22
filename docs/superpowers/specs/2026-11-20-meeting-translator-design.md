# 离线会议实时字幕翻译 App 架构设计

- 日期：2026-11-20
- 状态：待确认
- 前置材料：早期的 ChatGPT 方案笔记（不在本仓库中；本设计取代其架构部分，差异见第 11 节）

标注说明：**【已定】** 是需求方明确决定的；**【提议】** 是架构师的判断，可以推翻；**【待验证】** 必须在 Phase 0 真机上确认。

## 1. 意图

在 iPhone 18 Pro Max 上持续旁听会议或谈话，把外语实时识别出来并翻译成中文，以字幕形式显示。使用时不联网。

它是"字幕机"，不是"对讲翻译机"：用户不操作、不说话，只看屏幕。

## 2. 目标、非目标、反目标

### 目标

- 【已定】实时识别会议/谈话语音并翻译成中文。
- 【已定】使用时完全离线；首次安装允许联网一次性下载模型和语言包。
- 【已定】马来语不在首版范围，但架构必须能在不改动管线的前提下加入。
- 【提议】首版源语言为英语，其他语言（韩语、日语等）通过下载系统语言包启用，不需要改代码。
- 【提议】单场会议连续运行 2 小时不崩溃、不因过热降级到不可用。
- 【提议】会议记录本地保存，可回看、复制、导出为文本。

### 非目标（首版不做）

- 译文语音朗读（TTS）。
- 中文 → 外语的反向翻译、双人对讲模式。
- 说话人区分（谁说了哪句）。
- 同一场会议内切换源语言，无论自动还是手动。【提议】首版一场会议只有一种源语言，开始前选定；要换语言就结束当前会议再开一场。
- 保存原始录音。只存文字，理由是隐私和存储。
- 会议摘要、要点提取。
- App Store 上架流程。首版通过 Xcode 直接安装到自己的设备。

### 反目标（出现即视为失败）

- 识别或翻译过程中发起任何网络请求。
- 译文在屏幕上反复跳变，让人无法阅读。
- 翻译积压拖慢识别，导致字幕越来越滞后于讲话。
- 长会议中途因内存或发热被系统杀掉，且已有记录丢失。

## 3. 约束

- 设备：iPhone 18 Pro Max。最低系统版本 iOS 26（`SpeechAnalyzer` 的最低要求）。
- 开发环境：必须有 Mac 和 Xcode。当前工作目录在 Windows 上，只能用于编辑文档和源码，不能构建、签名或真机调试。【待确认】Mac 是否可用、目标 iPhone 的系统版本、是否有付费开发者账号。
- 代码规范：单个源文件不超过 200 行。
- 首版不引入第三方依赖，全部使用系统框架。

## 4. 方案选择

| 方案 | 做法 | 主要取舍 |
|---|---|---|
| A. Apple 原生为主 | `SpeechAnalyzer` 识别 + `Translation` 框架翻译，藏在协议后面 | 开发量最小、流式能力系统自带、能效最好；翻译质量为系统水平，语言覆盖由 Apple 决定 |
| B. 全开源模型栈 | VAD 切段 + Qwen3-ASR/Whisper + 本地翻译模型 | 语言覆盖自主；下载 2–4 GB，每句延迟 2–5 秒，切段、去重、发热全要自己处理，许可问题仍在 |
| C. Apple 识别 + 端侧 LLM 翻译 | 识别同 A，翻译换成 1–2 GB 的小型 LLM | 会议翻译质量更好、可带术语表；多一个推理运行时，持续推理的发热未知 |

【已定】选 **方案 A**。它把最难的流式识别交给系统，最快拿到可在真实会议里试用的版本。B 和 C 都是 A 的增量：协议边界划对之后，换翻译引擎得到 C，加识别引擎得到 B 中需要的部分。

## 5. 架构

### 5.1 管线

```
麦克风 ─▶ AudioCapture ─▶ ASREngine ─▶ SentenceAssembler ─▶ TranslationQueue ─▶ TranscriptStore ─▶ 字幕界面
                          (协议)        临时/定稿 → 整句       (Translator 协议)     (SwiftData)
                              │                                                        ▲
                              └────────────── 临时原文（不翻译，直接显示）──────────────┘
```

各阶段之间用 `AsyncStream` 传递，每个阶段是一个 actor。`SessionCoordinator` 负责装配、启动、停止和错误处理，界面只和它以及 `TranscriptStore` 打交道。

### 5.2 组件职责

| 组件 | 职责 | 首版实现 |
|---|---|---|
| `AudioCapture` | 配置音频会话，从麦克风取 PCM 缓冲，转成识别引擎要求的格式 | `AVAudioEngine` + `AVAudioConverter` |
| `ASREngine`（协议） | 输入音频流，输出识别事件流 | `AppleSpeechEngine`，封装 `SpeechAnalyzer` + `SpeechTranscriber` |
| `SentenceAssembler` | 把定稿片段拼成完整句子 | 纯 Swift 逻辑，无系统依赖 |
| `Translator`（协议） | 把一句原文翻成中文 | `AppleTranslator`，封装 `TranslationSession` |
| `TranslationQueue` | 按顺序翻译定稿句子，处理积压 | actor，内部持有 `Translator` |
| `TranscriptStore` | 保存会议和句子，供界面观察 | SwiftData |
| `ModelReadiness` | 检查并引导下载语言包，做离线自检 | `AssetInventory` + `LanguageAvailability` |
| `SessionCoordinator` | 装配管线，管理会话状态机 | `@Observable` 类 |

### 5.3 两个核心协议

```swift
protocol ASREngine: Sendable {
    /// 该引擎当前可用的源语言
    func supportedLocales() async -> [Locale]
    /// 引擎希望收到的音频格式
    func preferredFormat(for locale: Locale) async throws -> AVAudioFormat
    /// 开始识别；音频流结束时事件流随之结束
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>,
                    locale: Locale) -> AsyncThrowingStream<ASREvent, Error>
}

enum ASREvent: Sendable {
    case volatile(text: String)                      // 临时结果，会被后续结果替换
    case finalized(text: String, range: ClosedRange<TimeInterval>)  // 定稿，不再改变
}

protocol Translator: Sendable {
    func canTranslate(from source: Locale.Language) async -> Bool
    /// context 是前几句已定稿的原文；不支持上下文的引擎可以忽略
    func translate(_ text: String, from source: Locale.Language,
                   context: [String]) async throws -> String
}
```

设计要点：

- `ASREvent` 只有"临时"和"定稿"两种。原生流式引擎直接映射；将来的切段式开源引擎可以只发 `finalized`，管线下游不用改。
- `Translator` 的 `context` 参数现在用不上（系统翻译不接受上下文），是为方案 C 的 LLM 翻译预留的。目标语言固定为简体中文，不进接口。
- 协议里不出现任何 Apple 框架特有的类型，除了音频缓冲。

### 5.4 字幕稳定策略

这是体验的核心，规则如下：

1. 临时结果只显示原文，用浅色，随时被替换，**不翻译**。
2. 定稿片段进入 `SentenceAssembler`，按以下任一条件切出一句：遇到句末标点；累计超过长度上限；超过停顿时限没有新内容。
3. 切出的句子写入 `TranscriptStore`，状态为"待翻译"，原文立刻以正常颜色显示。
4. `TranslationQueue` 按顺序翻译，译文回填到同一条记录。**译文一旦显示就不再修改。**
5. 积压处理：【提议】队列里有多句待翻译时，用一次批量请求把它们一起送出，每句仍然各自得到一条译文，原文和译文始终一一对应。不做"多句并成一段再翻"，因为译文拆不回各句。
6. 无论积压多少都不丢句子。积压超过阈值时界面显示"翻译滞后"提示，原文照常实时显示。

长度上限、停顿时限、积压阈值的具体数值由 Phase 0 实测决定。

### 5.5 会话状态机

```
idle ─▶ preparing ─▶ listening ⇄ paused
            │            │
            ▼            ▼
          failed     finishing ─▶ idle
```

- `preparing`：检查语言包、申请麦克风权限、预热模型。
- `listening`：管线运行。禁用自动锁屏，前台亮屏是主要使用方式。同时启用后台音频模式：切到后台或锁屏后尽力继续识别，翻译允许回到前台后再补上。
- `paused`：来电、其他 App 占用音频等中断。中断结束后自动恢复，并在记录中插入一条"中断"标记。
- `finishing`：停止采集，等待识别引擎吐完剩余结果、翻译队列清空，再落盘。

### 5.6 模型与离线保证

- 首次启动进入引导页，由 `ModelReadiness` 完成：选择源语言 → 下载识别语言包 → 下载"源语言→中文"翻译语言包 → 离线自检。
- **离线自检**：下载完成后，用内置的一小段样例音频和一句样例文本，实际跑一次识别和翻译。有开发者报告过"状态显示已安装，但翻译时报离线模型不可用"的情况，所以不信任状态查询，只信任实际跑通。
- 每次开始会议前重复一次轻量检查；系统有可能回收语言包。
- App 自身不含任何网络代码。验收时在飞行模式下完成全流程。

### 5.7 数据模型

```
Meeting   { id, title, startedAt, endedAt, sourceLocale }
Segment   { id, meeting, index, sourceText, translatedText?, startTime, endTime, status }
          status: pendingTranslation | translated | translationFailed | interruptionMarker
```

句子每定稿一条就立即写盘，App 被杀也只丢失尚未定稿的那半句。翻译失败的句子保留原文，会后可重试。

### 5.8 界面

三个页面：

1. **引导/语言包管理**：源语言列表，每个语言显示"未下载 / 下载中 / 已就绪"。
2. **实时字幕**（主页面）：

   ```
   ┌──────────────────────────────────────────┐
   │ ● 英语 → 中文        00:42:17     [离线] │
   ├──────────────────────────────────────────┤
   │ We'll start the pilot run next Monday.   │  ← 原文，小字
   │ 我们下周一开始试生产。                   │  ← 译文，大字
   │                                          │
   │ The tooling should arrive by Friday.     │
   │ 模具应该周五之前到。                     │
   │                                          │
   │ and then we need to confirm the…         │  ← 临时结果，浅色
   ├──────────────────────────────────────────┤
   │        [ 暂停 ]        [ 结束会议 ]      │
   └──────────────────────────────────────────┘
   ```

   自动滚动到最新；用户手动上翻时停止自动滚动，出现"回到最新"按钮。支持横屏和字号调整。
3. **历史记录**：会议列表 → 会议详情（双语对照），可复制、导出为文本或 Markdown。

### 5.9 工程结构

```
MeetingTranslator/
├── App/                    入口、依赖装配
├── Features/
│   ├── Onboarding/         引导与语言包管理
│   ├── LiveCaption/        实时字幕页
│   └── History/            历史与导出
├── Pipeline/
│   ├── AudioCapture.swift
│   ├── SentenceAssembler.swift
│   ├── TranslationQueue.swift
│   └── SessionCoordinator.swift
├── Engines/
│   ├── ASREngine.swift     协议与事件类型
│   ├── Translator.swift    协议
│   └── Apple/              AppleSpeechEngine、AppleTranslator、ModelReadiness
├── Storage/                SwiftData 模型与 TranscriptStore
└── Tests/                  管线逻辑测试、假引擎、样例音频
```

将来的 `Engines/OpenSource/`、`Engines/LLM/` 与 `Engines/Apple/` 并列，其他目录不动。

## 6. 扩展路径

| 需求 | 做法 | 管线改动 |
|---|---|---|
| 马来语 | 先查系统是否已支持（见下）；不支持则新增一个开源模型实现的 `ASREngine` 和/或 `Translator` | 无 |
| 更高翻译质量、术语表 | 新增 LLM 实现的 `Translator`，使用 `context` 参数 | 无 |
| 说话人区分 | 在 `ASREngine` 之后并联一个说话人分析阶段，给 `Segment` 加字段 | 新增一个阶段 |
| 自动语言识别 | 在 `ASREngine` 之前加语言检测，由 `SessionCoordinator` 切换引擎 | 新增一个阶段 |

`SessionCoordinator` 按"源语言 → 引擎"的注册表选择实现，所以不同语言可以用不同引擎。

关于马来语：有媒体报道 iOS 27 测试版的系统翻译新增了马来语。这只说明翻译一侧可能已被系统覆盖，识别一侧仍未知。两者都需要在目标设备上查证后再决定马来语走哪条路。

## 7. Phase 0：真机验证（先于一切开发）

方案 A 成立的前提没有一条经过真机确认，网上的信息也互相矛盾（有开发者报告支持列表与实际不符）。因此先做一个一次性的验证小程序，回答：

1. 【待验证】目标设备上 `SpeechTranscriber.supportedLocales` 的实际内容，英语、韩语、马来语是否在内。
2. 【待验证】`LanguageAvailability` 对"英语→简体中文"及其他候选语言对的状态。
3. 【待验证】语言包下载后，飞行模式下识别和翻译能否实际跑通。
4. 【待验证】真实会议录音的识别质量（远场、多人、带口音），临时结果到定稿的延迟。
5. 【待验证】连续运行 120 分钟的内存曲线、温度状态和耗电。
6. 【待验证】后台或锁屏后识别和翻译各自能否继续。

**退出条件**【提议】：

- 第 1–3 条对英语全部通过，方案 A 继续。任何一条不通过，回到方案选择，优先考虑 B 的识别引擎配 A 的翻译。
- 第 4 条由需求方看实际字幕后主观判断"能不能用"。判为不能用时同样回到方案选择。
- 第 5 条：120 分钟内被系统杀掉，或温度状态升到系统开始限速并导致字幕明显滞后，视为不通过。先尝试降低负载（如关闭临时结果），仍不通过再回到方案选择。
- 第 6 条不阻塞 Phase 1。后台不能持续运行时，产品降级为"仅前台亮屏使用"，进入后台即转为 `paused`。

测试音频：Phase 0 和回归测试用两类录音。公开可用的英语会议或讲座录音放进仓库作为固定基准；需求方自己的真实会议录音只留在设备和本机，不进仓库。

验证小程序是一次性的，不进入正式工程。

## 8. 实施阶段

| 阶段 | 内容 | 完成标志 |
|---|---|---|
| Phase 0 | 真机验证（第 7 节） | 六个问题有实测答案 |
| Phase 1 | 管线 + 实时字幕页 + 最简引导 | 飞行模式下能看一场英语会议的中文字幕 |
| Phase 2 | 历史、导出、中断恢复、语言包管理、长时间稳定性 | 2 小时会议无崩溃、记录完整 |
| 扩展 | 第 6 节各项，按需 | — |

## 9. 测试策略

- `SentenceAssembler`、`TranslationQueue` 是纯逻辑，用假的事件流做单元测试，覆盖切句、积压合并、顺序保证、翻译失败。
- 管线集成测试用假的 `ASREngine` 和 `Translator`，不依赖系统模型，可在模拟器上跑。
- `AppleSpeechEngine` 支持以音频文件作为输入，用同一批样例录音做回归和引擎对比。有报告称模拟器上系统识别不可用，这部分只在真机上跑。
- 验收：飞行模式全流程；2 小时连续运行；来电中断后恢复；运行中强杀 App 后记录完好。

## 10. 留给实现者决定的事项

- 切句的长度上限、停顿时限和积压阈值的具体数值（依据 Phase 0 数据）。
- 音频会话的模式与缓冲大小。
- 界面的视觉细节、字号档位、配色。
- 导出文件的具体排版。
- SwiftData 的具体建模写法与迁移策略。

## 11. 与 ChatGPT 初步建议的差异

| 项目 | 初步建议 | 本设计 | 原因 |
|---|---|---|---|
| 产品形态 | 四语互译对讲机 | 单向中文字幕机 | 需求是旁听会议并译成中文 |
| 识别 | Qwen3-ASR（非流式） | 系统流式识别 | 实时字幕需要临时/定稿结果 |
| 翻译 | NLLB 或 Lingvanex，经英语中转 | 系统翻译，直译成中文 | 避开非商用许可和商务采购；只需一个方向 |
| TTS | 有 | 无 | 会议场景不需要 |
| 模型分发 | 打进安装包 | 系统语言包，首次下载 | 需求方允许首次联网 |
| 实时性 | 第二阶段改造 | 从第一版起就是管线的基础 | 它是核心需求 |
| 第一步 | 生成完整工程 | 真机验证前提 | 关键前提都未实测 |

## 参考

- [SpeechAnalyzer 文档](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber 文档](https://developer.apple.com/documentation/speech/speechtranscriber)
- [WWDC25：SpeechAnalyzer 介绍](https://developer.apple.com/videos/play/wwdc2025/277/)
- [TranslationSession 文档](https://developer.apple.com/documentation/translation/translationsession)
- [LanguageAvailability 文档](https://developer.apple.com/documentation/translation/languageavailability)
- [开发者论坛：状态为已安装但离线模型不可用](https://developer.apple.com/forums/thread/813109)
- [开发者论坛：部分语言资源下载失败](https://developer.apple.com/forums/thread/797835)
- [9to5Mac：iOS 27 系统翻译新增语言（含马来语，测试版信息）](https://9to5mac.com/2026/07/08/ios-27-adds-nine-new-languages-and-accents-to-apple-translate/)
