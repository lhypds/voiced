# Voiced

[English](README.md) | **中文** | [日本語](README.ja.md)

Voiced 是一个原生 macOS 本地实时语音识别应用。它可以监听任意 Core Audio 输入设备，包括麦克风以及 Loopback、BlackHole 虚拟设备，并按句显示带时间戳的转写内容。音频和转写内容不会离开本机。

## 模型

识别基于 WhisperKit 的 Core ML 模型。设置中提供两种识别引擎：

| 引擎 | 模型 | 说明 |
| --- | --- | --- |
| 高速（默认） | Whisper large-v3 Turbo（632 MB） | 响应更快、资源占用更低，适合实时字幕和配置较低的 Mac。 |
| 高精度 | Whisper large-v3（626 MB） | 中日英识别更准确，但响应较慢。 |

每个模型在首次选择时从 Hugging Face 下载，之后保存在本机缓存中。

识别语言：自动检测、中文、英文、日文、韩文、西班牙文、法文、德文、葡萄牙文、俄文。

界面语言：英文、中文、日文、法文、西班牙文、德文。

## 构建与运行

要求 macOS 14 或更高版本，推荐 Apple Silicon。

```sh
./Scripts/build-app.sh
open .build/Voiced.app
```

根目录的 `start.sh`、`stop.sh`、`restart.sh` 作用相同，并会在需要时自动重新构建。

首次运行需要允许麦克风访问。即使选择的是虚拟音频设备，macOS 仍会把它归类为麦克风输入，因此没有物理麦克风时也需要这项权限。

## 接入其他应用音频

1. 在 Loopback 中新建虚拟设备，把目标应用加入 Sources；或安装 BlackHole 并通过"音频 MIDI 设置"建立多输出设备。
2. 启动 Voiced，在左侧"输入"中选择对应虚拟设备。
3. 选择常用语言以提高精度；内容会频繁切换语言时选择"自动检测"。
4. 点击麦克风按钮开始，点击停止按钮结束。

使用 BlackHole 时，如果还需要从扬声器听到声音，应使用多输出设备同时路由到扬声器和 BlackHole。

## 设置

- 识别引擎、识别语言和界面语言。
- 窗口置顶：切换到其他应用时窗口仍保持在最前面。
- 时间戳：相对时间或当前时间，可选显示日期。
- 能量阈值：低于此值的声音不会识别。外放经麦克风拾取等较小的声源需要调低。
- 识别预览：用当前设置试听，显示输入电平和识别文本，不会写入正文。适合用来调整阈值。

## 磁盘上的数据

Voiced 保存的所有内容都在 `~/.voiced` 下：

```
~/.voiced/
  settings.json             设定
  history/<unix time>/      每条历史记录一个目录，以开始时刻的 Unix 时间（秒）命名
    transcript.json         转写内容，以及每次录音会话一条记录：开始/结束时间、输入设备、语言、引擎、音频文件名
    <unix time>.wav         每次录音会话的原始音频（16 kHz 单声道 16 位 PCM）
```

一次录音会话从点击开始到点击停止。第一次录音会建立记录目录；先在历史记录里选中一条再录音，新会话的音频会以自己的开始时刻命名，追加到同一目录。音频文件在录音过程中边录边写，即使应用意外退出也是完整的。没识别出任何句子的会话仍会保留音频；完全没有采到音频的会话不会留下任何东西。在历史记录里删除一条记录会连同目录和音频一起删除。保存的录音可以用 `VoicedSimulate` 重新喂给识别器（见 [docs/Develop.md](docs/Develop.md)）。

旧版本保存在 `UserDefaults` 和 `~/Library/Application Support/Voiced/History/` 里的设定和历史记录会在首次启动时自动挪到 `~/.voiced`。

## 历史记录

每次有句子提交时，当前转写会自动保存到 `~/.voiced/history/`。点击右上角的历史记录按钮可以选择一条旧记录放回屏幕，再次开始识别时新句子会追加在它后面。"新建"（加号）只清除屏幕并开始一条新记录，不删除已保存的记录；要删除记录在列表中点击垃圾桶图标。

## 开发

测试、文件模拟工具、代码结构和转写提交规则见 [docs/Develop.md](docs/Develop.md)。

## 资料

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [Loopback](https://rogueamoeba.com/loopback/)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)
