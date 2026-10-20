# Voiced

**English** | [中文](README.zh-CN.md) | [日本語](README.ja.md)

Voiced is a native macOS app for local, real-time speech recognition. It listens to any Core Audio input device, including microphones and Loopback or BlackHole virtual devices, and shows the transcript sentence by sentence with timestamps. Audio and transcripts never leave the machine.

## Models

Recognition runs on WhisperKit Core ML models. Two engines are available in Settings:

| Engine | Model | Notes |
| --- | --- | --- |
| Fast (default) | Whisper large-v3 Turbo (632 MB) | Faster responses, lower load. Suited to live captions and lower-end Macs. |
| Accurate | Whisper large-v3 (626 MB) | Better Chinese, Japanese and English accuracy at the cost of speed. |

Each model is downloaded from Hugging Face the first time it is selected and cached locally afterwards.

Recognition languages: auto detect, Chinese, English, Japanese, Korean, Spanish, French, German, Portuguese, Russian.

Interface languages: English, Chinese, Japanese, French, Spanish, German.

## Build and run

Requires macOS 14 or later. Apple Silicon is recommended.

```sh
./Scripts/build-app.sh
open .build/Voiced.app
```

`start.sh`, `stop.sh` and `restart.sh` in the repository root do the same and rebuild when needed.

The first launch asks for microphone access. macOS treats virtual audio devices as microphone input too, so the permission is needed even without a physical microphone.

## Capturing audio from other apps

1. In Loopback, create a virtual device and add the target app to its Sources. Or install BlackHole and create a Multi-Output Device in Audio MIDI Setup.
2. Launch Voiced and pick the virtual device under Input in the sidebar.
3. Pin the language you use most for better accuracy. Choose Auto detect when the content switches languages often.
4. Click the microphone button to start and the stop button to finish.

With BlackHole, use a Multi-Output Device that routes to both the speakers and BlackHole if you still want to hear the audio.

## Settings

- Recognition engine, recognition language and interface language.
- Keep window on top: the window stays in front when you switch to other apps.
- Timestamp: relative time or clock time, with an optional date.
- Energy threshold: sound below it is ignored. Lower it for quiet sources such as speakers picked up by a microphone.
- Measure background noise: keep quiet for 2 seconds. The room's noise is recorded for noise reduction and the threshold is set just above it, so fans or hum do not trigger recognition.
- Noise reduction: subtracts the measured background noise from the input before recognition. Available once the noise has been measured.
- Recognition preview: listens with the current settings and shows the input level and recognized text without writing to the transcript. Useful for tuning the threshold.

## Data on disk

Everything Voiced stores lives under `~/.voiced`:

```
~/.voiced/
  settings.json             preferences
  noise-profile.json        measured background noise, for noise reduction
  history/<unix time>/      one directory per history record, named after the time it was started
    transcript.json         the lines, plus one entry per recording session: start and end time,
                            input device, language, engine and the name of its audio file
    <unix time>.wav         the raw audio of all sessions, one after another (16 kHz mono 16-bit PCM)
```

A recording session runs from the start button to the stop button. The first session of a record creates its directory and its WAV file, named after the session's start time. Every later session recorded into the same record (by selecting it in the history first) continues that file, and its entry in `transcript.json` notes the offset, in seconds, where its audio starts. The audio file is written while recording, so it is complete even if the app quits unexpectedly. A session that recognized nothing still keeps its audio; one that captured no audio at all leaves nothing behind. Deleting a record in the history removes its directory with the audio. The saved audio can be replayed through the recognizer with `VoicedSimulate` (see [docs/Develop.md](docs/Develop.md)).

Settings and history written by earlier versions (in `UserDefaults` and `~/Library/Application Support/Voiced/History/`) are moved into `~/.voiced` on the first launch.

## History

Every time a sentence is committed, the current transcript is saved automatically to `~/.voiced/history/`. The history button in the top right lists past records; selecting one puts it back on screen, and starting recognition again appends new sentences after it. The new button (plus icon) empties the screen and starts a new record; the saved records are kept. To delete a record, click the trash icon in the list.

## Development

See [docs/Develop.md](docs/Develop.md) for tests, the file-based simulator, code layout and how sentences are committed.

## References

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
- [Loopback](https://rogueamoeba.com/loopback/)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)
