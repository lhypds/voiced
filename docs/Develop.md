# Development

## Building

```sh
swift build                 # debug build of all targets
./Scripts/build-app.sh      # release build, packaged as .build/Voiced.app
```

`start.sh` and `stop.sh` launch and quit the packaged app. `restart.sh` always rebuilds first so the running app picks up source changes.

The app icon in `Support/AppIcon.icns` is checked in. Run `Scripts/generate-icon.sh` to regenerate it.

## Release

```sh
./release.sh            # bump patch: 1.2.3 -> 1.2.4
./release.sh minor      # bump minor: 1.2.3 -> 1.3.0
./release.sh major      # bump major: 1.2.3 -> 2.0.0
./release.sh 1.5.0      # set an explicit version
```

The script reads `VERSION`, writes the new version to `VERSION` and `Support/Info.plist`, builds the app bundle, zips it, commits and tags `vX.Y.Z`, pushes, and creates a GitHub Release with the zip attached. It requires the `gh` CLI, a clean working tree on `master`, and `master` in sync with `origin/master`.

## Tests

Unit tests cover sentence assembly, session state, timestamp formatting, settings persistence, the noise calibration and spectral denoiser, the hallucination filter, the recognition prompt, the history store, the session recorder (WAV output) and the migration into `~/.voiced`:

```sh
swift test
```

`swift test` needs XCTest, which ships with a full Xcode install. With only the Command Line Tools, `swift build` works but the tests cannot run.

## Simulating live input from a file

The recognition pipeline can be exercised without speaking into a microphone:

```sh
say -v Kyoko -o sample.wav --data-format=LEI16@16000 "こんにちは [[slnc 3000]] さようなら"
swift run -c release VoicedSimulate sample.wav --lang ja
```

`VoicedSimulate` feeds the file into `LiveTranscriber` at real-time pace, prints every decode, commit and pause event, and checks that committed sentences never change afterwards and that the audio handed to the session recorder is exactly what was fed in. The WAV files saved under `~/.voiced/history/<record>/` are already 16 kHz mono and can be passed in directly.

| Option | Effect |
| --- | --- |
| `--lang <code>` | Recognition language (default `en`). |
| `--noise 0.02` | Add white noise of the given amplitude. |
| `--denoise` | Run the audio through spectral subtraction first, with a profile from noise of the `--noise` amplitude. Compare runs with and without it. |
| `--floor 0.01` | Energy threshold (default 0.02). |
| `--prompt-file path` | Recognition prompt file in the `~/.voiced/prompt.txt` format; compare runs with and without it. |
| `--energy` | Print only the energy values the VAD sees. |

## Model choice

- Whisper large-v3 handles Chinese, English, Japanese and many other languages, pinned or auto-detected.
- WhisperKit is native Swift, runs on the Apple Neural Engine, and supports streaming recognition with segment timestamps.
- [FluidAudio](https://github.com/FluidInference/FluidAudio)/Parakeet is faster, but its general multilingual model mostly covers European languages and Chinese needs a separate model, so it does not fit the mixed-language goal.

Model variants are listed in `RecognitionEngine.swift`. Chinese and Japanese transcripts are joined with full-width punctuation.

## How sentences are committed

- A sentence moves from LIVE into the transcript only once another segment has appeared after it. A sentence at the very end of the audio stays in LIVE even if it ends with punctuation, so the next decode can re-run it together with what follows and avoid cutting a sentence in half.
- After roughly 2 seconds of silence, whatever is in LIVE gets a closing period and is committed.
- Audio belonging to committed sentences is dropped from the buffer immediately, so later decodes can never rewrite them. The cut point is the quietest spot within 0.5 seconds before the Whisper sentence boundary, to avoid clipping the start of the next word.
- Continuous speech without punctuation is force-split after 15 seconds, so steady sources such as radio still commit sentence by sentence.
- A decode only runs when at least one frame of new audio reaches the energy threshold (default 0.02, WhisperKit's energy VAD default; adjustable in Settings between 0.002 and 0.05, effective immediately while recording). "Measure background noise" in Settings records 2 seconds from the input and sets the threshold to 1.5 times the loudest 100 ms frame, clamped to the same range, so steady room noise stays below it (`NoiseFloorCalibration.swift`). The same recording yields a noise profile, the average magnitude of each frequency bin (`NoiseProfile`, saved to `~/.voiced/noise-profile.json`).
- Noise reduction, on by default once a profile exists, is spectral subtraction (`SpectralDenoiser.swift`): 512-sample frames with 50% overlap and square-root Hann windows on both sides, twice the profile subtracted from each bin's magnitude, a gain floor of 0.1 and gain smoothing across frames to keep "musical noise" down. `DenoisingAudioSource` wraps WhisperKit's `AudioProcessor` and feeds the cleaned audio to the transcriber, so the voice detector, the level meter and the saved WAV all see the denoised signal. The threshold calibration then measures the denoised noise. Latency is 16 to 32 ms. Audio sent to Whisper is trimmed 0.5 seconds after the last speech frame so the model does not see a tail of background noise.
- A decoded segment is treated as a hallucination and discarded when the audio above the energy threshold lasts less than 0.2 seconds or less than 20% of the segment, when the average token log probability is below -1.5, or when the text matches a known hallucinated phrase (for example "ご視聴ありがとうございました" or "Thank you for watching"). WhisperKit does not implement `noSpeechProb`, so these heuristics are the only defence. The phrase list lives in `HallucinationFilter.swift`.
- Punctuation is normalized to the script of each line: Chinese text gets full-width marks with ，and 。, Japanese text gets 、and 。, and everything else gets ASCII marks followed by a space. The script is decided from the text itself (kana means Japanese, Han characters alone mean Japanese only when the language is set to 日本語), so English spoken in a Chinese session keeps half-width punctuation. See `PunctuationNormalizer.swift`.
- The LIVE line shows the text the current decode is producing, token by token, including the first decode of each utterance. Results emptied by the hallucination filter are not shown.
- Before a pause commits a sentence, any speech samples not yet decoded get one final decode so short words at the end are not lost.
- The recognition prompt (`RecognitionPrompt.swift`) is the standard Whisper "initial prompt": the non-comment lines of `~/.voiced/prompt.txt` are joined with commas, tokenized with the model's tokenizer and passed as `promptTokens`, which WhisperKit places after `<|startofprev|>` ahead of every decode. The prompt is cut to its first 223 tokens (WhisperKit would otherwise keep the last ones). It is read when a recording or preview starts, so edits take effect at the next start. The prompt only biases the decoder; it is not a replacement list, and a very long or off-language prompt can make the model echo prompt words, so keep it short.

## Code layout

```
Sources/Voiced/
  VoicedApp.swift              App entry point
  AppLocalization.swift        UI strings (English / Chinese / Japanese / French / Spanish / German)
  Models/                      Plain data types: TranscriptLine, RecognitionEngine, RecognitionLanguage
    TranscriptRecord.swift     A history record: lines plus one entry per recording session (with its offset in the shared WAV); its id is its directory name
    AppSettings.swift          Preferences, stored as JSON in ~/.voiced/settings.json
    VoicedDirectory.swift      Layout of ~/.voiced and migration of data from older versions
  Transcription/
    LiveTranscriber.swift      Streaming recognition loop with its own audio buffer: silence detection, dropping committed audio,
                               hands every captured sample to an audio sink before it can be dropped
    SessionRecorder.swift      Saves a session's raw audio as <unix time>.wav in the record's directory, or appends to the record's file
    WAVWriter.swift            Streaming 16-bit PCM WAV writer; header kept valid after every write, can reopen its own files to append
    HallucinationFilter.swift  Known hallucinated phrases
    RecognitionPrompt.swift    Reads ~/.voiced/prompt.txt and turns it into Whisper prompt tokens
    SentenceAssembler.swift    Merges recognition segments into sentences (pure function, unit tested)
    RecordingSession.swift     Commit state for one recording
    RecognitionPreview.swift   Throwaway recognition run for the Settings sheet (input level and preview text)
    NoiseFloorCalibration.swift Sets the energy threshold from a short recording of the background noise
    SpectralDenoiser.swift     Noise profile and streaming spectral subtraction (Accelerate FFT)
    DenoisingAudioSource.swift Microphone capture that runs the denoiser before the transcriber sees the audio
    WhisperModelStore.swift    Model cache check, download and loading
    TranscriptHistoryStore.swift  Reads and writes history (~/.voiced/history/<unix time>/transcript.json, one directory per record)
    TranscriptionController.swift  Connects recognition events to the UI
  Views/                       ContentView, SettingsView, HistoryView, Theme
Sources/VoicedSimulate/        Development tool that drives the pipeline with an audio file (sources are symlinks)
Tests/VoicedTests/             Unit tests for the pure logic above
Scripts/                       App bundling and icon generation
Support/                       Info.plist and the app icon
```
