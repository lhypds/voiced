# Voiced

Voiced 是一个原生 macOS 本地实时语音识别应用。它支持选择任意 Core Audio 输入设备，包括麦克风、Loopback 和 BlackHole，并按句显示起止时间戳。

## 模型选择

应用使用 WhisperKit 的 `large-v3-v20240930_turbo_632MB` Core ML 模型：

- Whisper large-v3 Turbo 支持中文、英文、日文等多语言，可手动指定语言或自动检测。
- WhisperKit 原生提供 Swift、Apple Neural Engine、流式识别和分段时间戳支持。
- 约 632 MB 的压缩 Turbo 模型在速度和准确率之间更适合实时桌面转写。
- FluidAudio/Parakeet 的推理速度更快，但通用多语言模型主要覆盖欧洲语言，中文需要另一套模型，因此不适合本应用的混合语言目标。

模型在首次启动时从 Hugging Face 下载，之后保存在本机缓存中。音频和转写不会上传。

## 构建与运行

要求 macOS 14 或更高版本，推荐 Apple Silicon。

```sh
swift build
./Scripts/build-app.sh
open .build/Voiced.app
```

日常开发可以直接用根目录的 `start.sh`、`stop.sh`、`restart.sh`，它们会在需要时自动打包。

单元测试覆盖句子合并、会话状态、时间戳格式、设置持久化和历史记录存储：

```sh
swift test
```

`swift test` 依赖 XCTest，需要安装完整的 Xcode；仅有 Command Line Tools 时 `swift build` 可用但测试无法运行。

## 转写提交规则

- 一句话只有在"后面已经出现别的段落"时才会从 LIVE 移入历史；处于音频末尾的句子即使有标点也先留在 LIVE，等下一次解码带着后文一起重解，避免把一句话从中间切断。
- 说话停顿约 2 秒后，LIVE 里的内容会补上句号并移入历史。
- 已移入历史的句子对应的音频会立即从缓冲区丢弃，之后的解码不可能再改写它们。丢弃点取 Whisper 句子边界前 0.5 秒内最安静的位置，避免切掉下一个词的开头。
- 没有标点的连续语音最长 15 秒会被强制断句，保证持续播放的内容（例如广播）也能逐句提交。
- 只有新音频中至少有一帧 RMS 达到能量阈值（默认 0.02，即 WhisperKit 能量 VAD 的默认值；可在设置里于 0.002～0.05 之间调整，录音中也即时生效）才会解码。外放经麦克风拾取等较小的声源需要调低。送入 Whisper 的音频会在最后一帧语音能量之后 0.5 秒截断，不把底噪尾巴交给模型。
- 解码出的片段若对应音频达到能量门槛的时长不足 0.2 秒、或不足片段时长的 20%，视为 Whisper 对静音的"幻听"并丢弃；平均 token 对数概率低于 -1.5 的片段同样丢弃；命中已知幻听短语表（如"ご視聴ありがとうございました"、"Thank you for watching"）的内容也会被剔除。WhisperKit 没有实现 `noSpeechProb`，所以只能靠这些手段。短语表在 `HallucinationFilter.swift`。
- LIVE 行实时显示当前解码正在产出的文本（逐 token 更新），包括每段话的第一次解码；经过幻听过滤的空结果不会显示。
- 停顿提交前，如果还有未解码的语音采样会先做一次最终解码，避免句尾短词丢失。

## 用文件模拟实时输入

不用对着麦克风说话也能验证识别流程：

```sh
say -v Kyoko -o sample.wav --data-format=LEI16@16000 "こんにちは [[slnc 3000]] さようなら"
swift run -c release VoicedSimulate sample.wav --lang ja
```

`VoicedSimulate` 按实时节奏把文件喂给 `LiveTranscriber`，打印每次解码、提交和停顿事件，并检查已提交的句子是否发生过变化。`--noise 0.02` 叠加白噪声，`--floor 0.01` 指定能量阈值（默认 0.02），`--energy` 只输出 VAD 看到的能量值。

## 代码结构

```
Sources/Voiced/
  VoicedApp.swift              应用入口
  AppLocalization.swift        界面文案（中 / 日 / 英）
  Models/                      纯数据类型：TranscriptLine、TranscriptRecord、RecognitionEngine、RecognitionLanguage、AppSettings
  Transcription/
    LiveTranscriber.swift      自管音频缓冲的流式识别循环：静音检测、已提交音频丢弃
    HallucinationFilter.swift  已知幻听短语表
    SentenceAssembler.swift    把识别片段合并成句子（纯函数，可测试）
    RecordingSession.swift     一次录音内的转写提交状态
    WhisperModelStore.swift    模型缓存检查、下载与加载
    TranscriptHistoryStore.swift  历史记录的读写（Application Support/Voiced/History，每条一个 JSON）
    TranscriptionController.swift  连接识别事件与 UI 的控制器
  Views/                       ContentView、SettingsView、HistoryView、Theme
Sources/VoicedSimulate/        用音频文件驱动识别流程的开发工具（源码为符号链接）
Tests/VoicedTests/             上述纯逻辑的单元测试
Scripts/                       打包与图标生成
Support/                       Info.plist 与应用图标
```

首次运行需要允许麦克风访问。即使选择的是虚拟音频设备，macOS 仍会把它归类为麦克风输入。

## 接入其他应用音频

1. 在 Loopback 中新建虚拟设备，把目标应用加入 Sources；或安装 BlackHole 并通过“音频 MIDI 设置”建立多输出设备。
2. 启动 Voiced，在左侧“输入”中选择对应虚拟设备。
3. 选择常用语言以提高精度；内容会频繁切换语言时选择“自动检测”。
4. 点击麦克风按钮开始，点击停止按钮结束。

## 历史记录

每次有句子提交时，当前转写会自动保存到 `~/Library/Application Support/Voiced/History/`。点击右上角的历史记录按钮可以选择一条旧记录放回屏幕，再次开始识别时新句子会追加在它后面。“清空”只清除屏幕，不删除已保存的记录；要删除记录在列表中点击垃圾桶图标。

使用 BlackHole 时，如果还需要从扬声器听到声音，应使用多输出设备同时路由到扬声器和 BlackHole。

## 资料

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [Loopback](https://rogueamoeba.com/loopback/)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)