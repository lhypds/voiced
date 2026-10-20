# Development

[English](#english) | [中文](#中文)

---

## English

### Building

```sh
swift build                 # debug build of all targets
./Scripts/build-app.sh      # release build, packaged as .build/Voiced.app
```

`start.sh` and `stop.sh` launch and quit the packaged app. `restart.sh` always rebuilds first so the running app picks up source changes.

The app icon in `Support/AppIcon.icns` is checked in. Run `Scripts/generate-icon.sh` to regenerate it.

### Release

```sh
./release.sh            # bump patch: 1.2.3 -> 1.2.4
./release.sh minor      # bump minor: 1.2.3 -> 1.3.0
./release.sh major      # bump major: 1.2.3 -> 2.0.0
./release.sh 1.5.0      # set an explicit version
```

The script reads `VERSION`, writes the new version to `VERSION` and `Support/Info.plist`, builds the app bundle, zips it, commits and tags `vX.Y.Z`, pushes, and creates a GitHub Release with the zip attached. It requires the `gh` CLI, a clean working tree on `master`, and `master` in sync with `origin/master`.

### Tests

Unit tests cover sentence assembly, session state, timestamp formatting, settings persistence, the hallucination filter and the history store:

```sh
swift test
```

`swift test` needs XCTest, which ships with a full Xcode install. With only the Command Line Tools, `swift build` works but the tests cannot run.

### Simulating live input from a file

The recognition pipeline can be exercised without speaking into a microphone:

```sh
say -v Kyoko -o sample.wav --data-format=LEI16@16000 "こんにちは [[slnc 3000]] さようなら"
swift run -c release VoicedSimulate sample.wav --lang ja
```

`VoicedSimulate` feeds the file into `LiveTranscriber` at real-time pace, prints every decode, commit and pause event, and checks that committed sentences never change afterwards.

| Option | Effect |
| --- | --- |
| `--lang <code>` | Recognition language (default `en`). |
| `--noise 0.02` | Add white noise of the given amplitude. |
| `--floor 0.01` | Energy threshold (default 0.02). |
| `--energy` | Print only the energy values the VAD sees. |

### Model choice

- Whisper large-v3 handles Chinese, English, Japanese and many other languages, pinned or auto-detected.
- WhisperKit is native Swift, runs on the Apple Neural Engine, and supports streaming recognition with segment timestamps.
- [FluidAudio](https://github.com/FluidInference/FluidAudio)/Parakeet is faster, but its general multilingual model mostly covers European languages and Chinese needs a separate model, so it does not fit the mixed-language goal.

Model variants are listed in `RecognitionEngine.swift`. Chinese and Japanese transcripts are joined with full-width punctuation.

### How sentences are committed

- A sentence moves from LIVE into the transcript only once another segment has appeared after it. A sentence at the very end of the audio stays in LIVE even if it ends with punctuation, so the next decode can re-run it together with what follows and avoid cutting a sentence in half.
- After roughly 2 seconds of silence, whatever is in LIVE gets a closing period and is committed.
- Audio belonging to committed sentences is dropped from the buffer immediately, so later decodes can never rewrite them. The cut point is the quietest spot within 0.5 seconds before the Whisper sentence boundary, to avoid clipping the start of the next word.
- Continuous speech without punctuation is force-split after 15 seconds, so steady sources such as radio still commit sentence by sentence.
- A decode only runs when at least one frame of new audio reaches the energy threshold (default 0.02, WhisperKit's energy VAD default; adjustable in Settings between 0.002 and 0.05, effective immediately while recording). Audio sent to Whisper is trimmed 0.5 seconds after the last speech frame so the model does not see a tail of background noise.
- A decoded segment is treated as a hallucination and discarded when the audio above the energy threshold lasts less than 0.2 seconds or less than 20% of the segment, when the average token log probability is below -1.5, or when the text matches a known hallucinated phrase (for example "ご視聴ありがとうございました" or "Thank you for watching"). WhisperKit does not implement `noSpeechProb`, so these heuristics are the only defence. The phrase list lives in `HallucinationFilter.swift`.
- The LIVE line shows the text the current decode is producing, token by token, including the first decode of each utterance. Results emptied by the hallucination filter are not shown.
- Before a pause commits a sentence, any speech samples not yet decoded get one final decode so short words at the end are not lost.

### Code layout

```
Sources/Voiced/
  VoicedApp.swift              App entry point
  AppLocalization.swift        UI strings (English / Chinese / Japanese / French / Spanish / German)
  Models/                      Plain data types: TranscriptLine, TranscriptRecord, RecognitionEngine, RecognitionLanguage, AppSettings
  Transcription/
    LiveTranscriber.swift      Streaming recognition loop with its own audio buffer: silence detection, dropping committed audio
    HallucinationFilter.swift  Known hallucinated phrases
    SentenceAssembler.swift    Merges recognition segments into sentences (pure function, unit tested)
    RecordingSession.swift     Commit state for one recording
    RecognitionPreview.swift   Throwaway recognition run for the Settings sheet (input level and preview text)
    WhisperModelStore.swift    Model cache check, download and loading
    TranscriptHistoryStore.swift  Reads and writes history (Application Support/Voiced/History, one JSON file per record)
    TranscriptionController.swift  Connects recognition events to the UI
  Views/                       ContentView, SettingsView, HistoryView, Theme
Sources/VoicedSimulate/        Development tool that drives the pipeline with an audio file (sources are symlinks)
Tests/VoicedTests/             Unit tests for the pure logic above
Scripts/                       App bundling and icon generation
Support/                       Info.plist and the app icon
```

---

## 中文

### 构建

```sh
swift build                 # 所有 target 的 debug 构建
./Scripts/build-app.sh      # release 构建并打包为 .build/Voiced.app
```

`start.sh` 和 `stop.sh` 用于启动和退出打包后的应用。`restart.sh` 每次都会先重新构建，以便运行中的应用拿到最新的源码改动。

应用图标 `Support/AppIcon.icns` 已提交到仓库，运行 `Scripts/generate-icon.sh` 可重新生成。

### 发布

```sh
./release.sh            # patch：1.2.3 -> 1.2.4
./release.sh minor      # minor：1.2.3 -> 1.3.0
./release.sh major      # major：1.2.3 -> 2.0.0
./release.sh 1.5.0      # 直接指定版本
```

脚本读取 `VERSION`，把新版本写回 `VERSION` 和 `Support/Info.plist`，构建并打包为 zip，提交并打上 `vX.Y.Z` 标签，推送后用 zip 创建 GitHub Release。需要 `gh` CLI、干净的 `master` 工作区，且 `master` 与 `origin/master` 一致。

### 测试

单元测试覆盖句子合并、会话状态、时间戳格式、设置持久化、幻听过滤和历史记录存储：

```sh
swift test
```

`swift test` 依赖 XCTest，需要安装完整的 Xcode；仅有 Command Line Tools 时 `swift build` 可用但测试无法运行。

### 用文件模拟实时输入

不用对着麦克风说话也能验证识别流程：

```sh
say -v Kyoko -o sample.wav --data-format=LEI16@16000 "こんにちは [[slnc 3000]] さようなら"
swift run -c release VoicedSimulate sample.wav --lang ja
```

`VoicedSimulate` 按实时节奏把文件喂给 `LiveTranscriber`，打印每次解码、提交和停顿事件，并检查已提交的句子是否发生过变化。

| 参数 | 作用 |
| --- | --- |
| `--lang <code>` | 识别语言（默认 `en`）。 |
| `--noise 0.02` | 叠加指定幅度的白噪声。 |
| `--floor 0.01` | 能量阈值（默认 0.02）。 |
| `--energy` | 只输出 VAD 看到的能量值。 |

### 模型选择

- Whisper large-v3 支持中文、英文、日文等多语言，可手动指定语言或自动检测。
- WhisperKit 原生使用 Swift，运行在 Apple Neural Engine 上，支持流式识别和分段时间戳。
- [FluidAudio](https://github.com/FluidInference/FluidAudio)/Parakeet 的推理速度更快，但通用多语言模型主要覆盖欧洲语言，中文需要另一套模型，因此不适合混合语言的目标。

模型变体定义在 `RecognitionEngine.swift`。中文和日文的转写使用全角标点连接。

### 转写提交规则

- 一句话只有在"后面已经出现别的段落"时才会从 LIVE 移入历史；处于音频末尾的句子即使有标点也先留在 LIVE，等下一次解码带着后文一起重解，避免把一句话从中间切断。
- 说话停顿约 2 秒后，LIVE 里的内容会补上句号并移入历史。
- 已移入历史的句子对应的音频会立即从缓冲区丢弃，之后的解码不可能再改写它们。丢弃点取 Whisper 句子边界前 0.5 秒内最安静的位置，避免切掉下一个词的开头。
- 没有标点的连续语音最长 15 秒会被强制断句，保证持续播放的内容（例如广播）也能逐句提交。
- 只有新音频中至少有一帧 RMS 达到能量阈值（默认 0.02，即 WhisperKit 能量 VAD 的默认值；可在设置里于 0.002～0.05 之间调整，录音中也即时生效）才会解码。送入 Whisper 的音频会在最后一帧语音能量之后 0.5 秒截断，不把底噪尾巴交给模型。
- 解码出的片段若对应音频达到能量门槛的时长不足 0.2 秒、或不足片段时长的 20%，视为 Whisper 对静音的"幻听"并丢弃；平均 token 对数概率低于 -1.5 的片段同样丢弃；命中已知幻听短语表（如"ご視聴ありがとうございました"、"Thank you for watching"）的内容也会被剔除。WhisperKit 没有实现 `noSpeechProb`，所以只能靠这些手段。短语表在 `HallucinationFilter.swift`。
- LIVE 行实时显示当前解码正在产出的文本（逐 token 更新），包括每段话的第一次解码；经过幻听过滤的空结果不会显示。
- 停顿提交前，如果还有未解码的语音采样会先做一次最终解码，避免句尾短词丢失。

### 代码结构

```
Sources/Voiced/
  VoicedApp.swift              应用入口
  AppLocalization.swift        界面文案（英 / 中 / 日 / 法 / 西 / 德）
  Models/                      纯数据类型：TranscriptLine、TranscriptRecord、RecognitionEngine、RecognitionLanguage、AppSettings
  Transcription/
    LiveTranscriber.swift      自管音频缓冲的流式识别循环：静音检测、已提交音频丢弃
    HallucinationFilter.swift  已知幻听短语表
    SentenceAssembler.swift    把识别片段合并成句子（纯函数，可测试）
    RecordingSession.swift     一次录音内的转写提交状态
    RecognitionPreview.swift   设置面板里的试听识别（显示输入电平和预览文本，不写入正文）
    WhisperModelStore.swift    模型缓存检查、下载与加载
    TranscriptHistoryStore.swift  历史记录的读写（Application Support/Voiced/History，每条一个 JSON）
    TranscriptionController.swift  连接识别事件与 UI 的控制器
  Views/                       ContentView、SettingsView、HistoryView、Theme
Sources/VoicedSimulate/        用音频文件驱动识别流程的开发工具（源码为符号链接）
Tests/VoicedTests/             上述纯逻辑的单元测试
Scripts/                       打包与图标生成
Support/                       Info.plist 与应用图标
```
