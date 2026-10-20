# Voiced

[English](#english) | [中文](#中文)

---

## English

Voiced is a native macOS app for local, real-time speech recognition. It listens to any Core Audio input device, including microphones and Loopback or BlackHole virtual devices, and shows the transcript sentence by sentence with timestamps. Audio and transcripts never leave the machine.

### Models

Recognition runs on WhisperKit Core ML models. Two engines are available in Settings:

| Engine | Model | Notes |
| --- | --- | --- |
| Fast (default) | Whisper large-v3 Turbo (632 MB) | Faster responses, lower load. Suited to live captions and lower-end Macs. |
| Accurate | Whisper large-v3 (626 MB) | Better Chinese, Japanese and English accuracy at the cost of speed. |

Each model is downloaded from Hugging Face the first time it is selected and cached locally afterwards.

Recognition languages: auto detect, Chinese, English, Japanese, Korean, Spanish, French, German, Portuguese, Russian.

Interface languages: English, Chinese, Japanese, French, Spanish, German.

### Build and run

Requires macOS 14 or later. Apple Silicon is recommended.

```sh
./Scripts/build-app.sh
open .build/Voiced.app
```

`start.sh`, `stop.sh` and `restart.sh` in the repository root do the same and rebuild when needed.

The first launch asks for microphone access. macOS treats virtual audio devices as microphone input too, so the permission is needed even without a physical microphone.

### Capturing audio from other apps

1. In Loopback, create a virtual device and add the target app to its Sources. Or install BlackHole and create a Multi-Output Device in Audio MIDI Setup.
2. Launch Voiced and pick the virtual device under Input in the sidebar.
3. Pin the language you use most for better accuracy. Choose Auto detect when the content switches languages often.
4. Click the microphone button to start and the stop button to finish.

With BlackHole, use a Multi-Output Device that routes to both the speakers and BlackHole if you still want to hear the audio.

### Settings

- Recognition engine, recognition language and interface language.
- Timestamp: relative time or clock time, with an optional date.
- Energy threshold: sound below it is ignored. Lower it for quiet sources such as speakers picked up by a microphone.
- Recognition preview: listens with the current settings and shows the input level and recognized text without writing to the transcript. Useful for tuning the threshold.

### History

Every time a sentence is committed, the current transcript is saved automatically to `~/Library/Application Support/Voiced/History/`. The history button in the top right lists past records; selecting one puts it back on screen, and starting recognition again appends new sentences after it. Clear only empties the screen and keeps the saved records. To delete a record, click the trash icon in the list.

### Development

See [docs/Develop.md](docs/Develop.md) for tests, the file-based simulator, code layout and how sentences are committed.

### References

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [Loopback](https://rogueamoeba.com/loopback/)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)

---

## 中文

Voiced 是一个原生 macOS 本地实时语音识别应用。它可以监听任意 Core Audio 输入设备，包括麦克风以及 Loopback、BlackHole 虚拟设备，并按句显示带时间戳的转写内容。音频和转写内容不会离开本机。

### 模型

识别基于 WhisperKit 的 Core ML 模型。设置中提供两种识别引擎：

| 引擎 | 模型 | 说明 |
| --- | --- | --- |
| 高速（默认） | Whisper large-v3 Turbo（632 MB） | 响应更快、资源占用更低，适合实时字幕和配置较低的 Mac。 |
| 高精度 | Whisper large-v3（626 MB） | 中日英识别更准确，但响应较慢。 |

每个模型在首次选择时从 Hugging Face 下载，之后保存在本机缓存中。

识别语言：自动检测、中文、英文、日文、韩文、西班牙文、法文、德文、葡萄牙文、俄文。

界面语言：英文、中文、日文、法文、西班牙文、德文。

### 构建与运行

要求 macOS 14 或更高版本，推荐 Apple Silicon。

```sh
./Scripts/build-app.sh
open .build/Voiced.app
```

根目录的 `start.sh`、`stop.sh`、`restart.sh` 作用相同，并会在需要时自动重新构建。

首次运行需要允许麦克风访问。即使选择的是虚拟音频设备，macOS 仍会把它归类为麦克风输入，因此没有物理麦克风时也需要这项权限。

### 接入其他应用音频

1. 在 Loopback 中新建虚拟设备，把目标应用加入 Sources；或安装 BlackHole 并通过"音频 MIDI 设置"建立多输出设备。
2. 启动 Voiced，在左侧"输入"中选择对应虚拟设备。
3. 选择常用语言以提高精度；内容会频繁切换语言时选择"自动检测"。
4. 点击麦克风按钮开始，点击停止按钮结束。

使用 BlackHole 时，如果还需要从扬声器听到声音，应使用多输出设备同时路由到扬声器和 BlackHole。

### 设置

- 识别引擎、识别语言和界面语言。
- 时间戳：相对时间或当前时间，可选显示日期。
- 能量阈值：低于此值的声音不会识别。外放经麦克风拾取等较小的声源需要调低。
- 识别预览：用当前设置试听，显示输入电平和识别文本，不会写入正文。适合用来调整阈值。

### 历史记录

每次有句子提交时，当前转写会自动保存到 `~/Library/Application Support/Voiced/History/`。点击右上角的历史记录按钮可以选择一条旧记录放回屏幕，再次开始识别时新句子会追加在它后面。"清空"只清除屏幕，不删除已保存的记录；要删除记录在列表中点击垃圾桶图标。

### 开发

测试、文件模拟工具、代码结构和转写提交规则见 [docs/Develop.md](docs/Develop.md)。

### 资料

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [Loopback](https://rogueamoeba.com/loopback/)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)
