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

Unit tests cover sentence assembly, session state, timestamp formatting, settings persistence, the noise calibration and spectral denoiser, the voice detector's bookkeeping (and the model itself when it is cached), the hallucination filter, the recognition prompt, the history store, the session recorder (WAV output) and the migration into `~/.voiced`:

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
| `--engine accurate` | Model to use: `turbo` (default), `accurate`, `belleTurbo` or `kotoba`; it must already be cached by the app. |
| `--noise 0.02` | Add white noise of the given amplitude. |
| `--denoise` | Run the audio through spectral subtraction first, with a profile from noise of the `--noise` amplitude. Compare runs with and without it. |
| `--floor 0.01` | Energy threshold (default 0.02). |
| `--prompt-file path` | Recognition prompt file in the `~/.voiced/prompt.txt` format; compare runs with and without it. |
| `--vad` | Filter the energy gate with the Silero voice detector, as the voice filter setting does; downloads the model on first use. Compare runs with and without it. |
| `--energy` | Print only the energy values the VAD sees, without loading the Whisper model. With `--vad`, also each 100 ms frame's highest speech probability. |

## Model choice

- Whisper large-v3 handles Chinese, English, Japanese and many other languages, pinned or auto-detected.
- WhisperKit is native Swift, runs on the Apple Neural Engine, and supports streaming recognition with segment timestamps.
- [FluidAudio](https://github.com/FluidInference/FluidAudio)/Parakeet is faster, but its general multilingual model mostly covers European languages and Chinese needs a separate model, so it does not fit the mixed-language goal.

Model variants are listed in `RecognitionEngine.swift`, each with the Hugging Face repository and folder it lives in; `WhisperModelStore` caches them under `~/Documents/huggingface/models/<repo>/<folder>`, the layout WhisperKit's downloader uses. The Belle model is Whisper large-v3 Turbo fine-tuned on Mandarin by the BELLE team, loaded from a community Core ML conversion; WhisperKit detects the architecture from the Core ML bundles, so a conversion needs only the three `.mlmodelc` folders. The Kotoba model is kotoba-whisper-v2.2, Whisper large-v3 distilled to a two-layer decoder on Japanese television speech; its conversion exposes no alignment heads, so word timings are unavailable and lines follow Whisper's segment boundaries, and the checkpoint emits no punctuation. The full Belle large-v3 fine-tune (`holgt/belle-whisper-large-v3-zh-coreml`) was tried and rejected: unquantized, it decoded at 6 to 20 seconds per window on an M-series Mac, and that checkpoint emits no punctuation at all, so lines could not be split. Chinese and Japanese transcripts are joined with full-width punctuation.

## How sentences are committed

- A sentence moves from LIVE into the transcript only once another segment has appeared after it. A sentence at the very end of the audio stays in LIVE even if it ends with punctuation, so the next decode can re-run it together with what follows and avoid cutting a sentence in half.
- After roughly 2 seconds of silence, whatever is in LIVE gets a closing period and is committed.
- Audio belonging to committed sentences is dropped from the buffer immediately, so later decodes can never rewrite them. The cut point is the start of the pause nearest to the boundary, searched 0.5 seconds either side of it (a pause just after the boundary means the boundary was a word timing that ended early), or the quietest 20 ms frame from 0.5 seconds before the boundary to 0.1 seconds after it when there is no pause (continuous speech such as news has none), to avoid clipping the start of the next word.
- When a decode of at least 5 seconds of speech keeps nothing, Whisper could not make sense of the window, usually because it opens on a clipped word. Every later decode would fail the same way while the buffer grows, until WhisperKit's 30 s window moves past the bad start on its own and half a minute of speech is gone. Instead the buffer is resynced: it restarts at the first quiet frame between 1 and 3 seconds into the window, losing a word at most.
- Decoding runs with word timestamps, and each Whisper segment is first cut into pieces after every word that ends with clause or sentence punctuation (`LiveTranscriber.splitAtPunctuation`). The assembler joins pieces that end with punctuation back without adding any, so this is lossless, and it lets a sentence close inside a segment. That matters for the Belle model and for any model given a prompt: both tend to return one long punctuated segment per window instead of one segment per clause.
- A short line that starts before the committed end and repeats the tail of the previous line is dropped (`RecordingSession.isRepeatedTail`): a word timing ends a little before the word's sound does, and when the cut leaves that tail in the buffer the next decode returns it again.
- Continuous speech without terminal punctuation is split at the next Whisper segment boundary once a sentence spans 8 seconds, so steady sources such as news or radio still commit line by line. Whisper rarely closes Chinese or Japanese sentences with 。, so for those this is the usual line length.
- A decode only runs when at least one frame of new audio reaches the energy threshold (default 0.02, WhisperKit's energy VAD default; adjustable in Settings between 0.002 and 0.05, effective immediately while recording). "Measure background noise" in Settings records 2 seconds from the input and sets the threshold to 1.5 times the loudest 100 ms frame, clamped to the same range, so steady room noise stays below it (`NoiseFloorCalibration.swift`). The same recording yields a noise profile, the average magnitude of each frequency bin (`NoiseProfile`, saved to `~/.voiced/noise-profile.json`).
- Noise reduction, on by default once a profile exists, is spectral subtraction (`SpectralDenoiser.swift`): 512-sample frames with 50% overlap and square-root Hann windows on both sides, twice the profile subtracted from each bin's magnitude, a gain floor of 0.1 and gain smoothing across frames to keep "musical noise" down. `MicrophoneAudioSource` runs the denoiser on the captured audio before the transcriber sees it, so the voice detector, the level meter and the saved WAV all see the denoised signal. The threshold calibration then measures the denoised noise. Latency is 16 to 32 ms. Audio sent to Whisper is cut 0.5 seconds before the first speech frame and 0.5 seconds after the last, so the model sees neither the lead-in nor a tail of background noise; both make it guess text over the noise.
- The voice filter, off by default, runs the Silero VAD model over every captured sample (`VoiceDetector.swift`; the Core ML build from FluidInference, which `VoiceDetectorModelStore` downloads to `~/Documents/huggingface/models/FluidInference/silero-vad-coreml`). The model judges 32 ms chunks on the CPU, carrying its recurrent state from one chunk to the next; 170 s of audio takes about 0.4 s. A 100 ms frame then counts as speech only when it reaches the energy floor *and* a chunk overlapping it scored at least 0.5, so the decode trigger, the pause, the hallucination check and the trimming of the decode input all ignore sound that is loud but not speech, such as music. The verdicts are kept by capture sample index (`VoiceActivity`), so they stay valid while the buffer's front moves; audio no chunk has judged yet is left to the energy gate. The model judges speech by its sound, not its level: a sentence at a peak of 0.03 is detected as well as one at 0.9, so the energy floor remains the only control over quiet sources. It hears what the transcriber hears, that is the denoised signal when noise reduction is on. Spectral subtraction cannot remove music: its profile is one fixed average spectrum, and music changes every beat.
- A decode is aborted only when its recent tokens repeat (a decoding loop). WhisperKit's streaming example also aborts as soon as the average log probability falls below the threshold, but that verdict is made on the first few tokens: a window that opens on a breath or half a word would throw away all the speech behind it, and with a steady source the same window opens the same way on every decode, so whole sentences went missing. Confidence is checked per segment after the decode instead.
- A decoded segment is treated as a hallucination and discarded when the audio above the energy threshold lasts less than 0.2 seconds or less than 20% of the segment, when the average token log probability is below -1.5, or when the text matches a known hallucinated phrase (for example "ご視聴ありがとうございました" or "Thank you for watching"). WhisperKit does not implement `noSpeechProb`, so these heuristics are the only defence. The phrase list lives in `HallucinationFilter.swift`.
- Punctuation is normalized to the script of each line: Chinese text gets full-width marks with ，and 。, Japanese text gets 、and 。, and everything else gets ASCII marks followed by a space. The script is decided from the text itself (kana means Japanese, Han characters alone mean Japanese only when the language is set to 日本語), so English spoken in a Chinese session keeps half-width punctuation. See `PunctuationNormalizer.swift`.
- The LIVE line shows the text the current decode is producing, token by token, including the first decode of each utterance. Results emptied by the hallucination filter are not shown.
- Before a pause commits a sentence, any speech samples not yet decoded get one final decode so short words at the end are not lost.
- The recognition prompt (`RecognitionPrompt.swift`) is the standard Whisper "initial prompt": the non-comment lines of `~/.voiced/prompt.txt` are joined with commas, tokenized with the model's tokenizer and passed as `promptTokens`, which WhisperKit places after `<|startofprev|>` ahead of every decode. The prompt is cut to its first 223 tokens (WhisperKit would otherwise keep the last ones). It is read when a recording or preview starts, so edits take effect at the next start. The prompt only biases the decoder; it is not a replacement list, and a very long or off-language prompt can make the model echo prompt words, so keep it short.

## Translation

- Committed lines are translated by Apple's Translation framework, on the device. The framework issues a `TranslationSession` only to a SwiftUI view through `translationTask`, valid only while that task runs, so `TranslationHost` attaches the task to the main window's content and `AppleTranslator.serve` keeps it running until the configuration changes or the window goes. `translate` calls wait for a session when none is serving yet.
- The source language is the pinned recognition language, or left to the framework when recognition auto-detects. The target is one of the interface languages. When the two are the same the translator is left unconfigured and no translation is shown.
- `TranscriptionController.translateVisibleLines` translates the visible lines that lack a translation in the target language, newest first and one at a time; it runs after every commit, when a record is resumed and whenever the translation settings change. `RecordingSession` knows nothing of translations: each commit rebuilds the transcript, and `keepingTranslations(from:)` copies the translations over by line id and text. A translation is stored on the line (`TranslatedText`, with its language code) and saved to `transcript.json` with the record; an empty one records that the line was already in the target language, so it is neither shown nor retried. A line the framework rejects is skipped until the translator is next configured, and the error is shown under the setting.
- Lines written before translation existed have no `translation` key and decode as untranslated.

## Code layout

```
Sources/Voiced/
  VoicedApp.swift              App entry point
  AppLocalization.swift        UI strings (English / Chinese / Japanese / French / Spanish / German)
  Models/                      Plain data types: TranscriptLine (with its optional TranslatedText), RecognitionEngine, RecognitionLanguage
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
    InputCapture.swift         Audio capture on the app's own AVAudioEngine, resampled to 16 kHz; survives a Bluetooth headset switching its sample rate
    MicrophoneAudioSource.swift Capture source for the transcriber, with the denoiser in front when a noise profile exists
    VoiceDetector.swift        Silero VAD speech detection (Core ML) and the per-chunk verdicts the transcriber keeps
    VoiceDetectorModelStore.swift  Cache check and download of the voice detector model
    WhisperModelStore.swift    Model cache check, download and loading
    TranscriptHistoryStore.swift  Reads and writes history (~/.voiced/history/<unix time>/transcript.json, one directory per record)
    SentenceTranslator.swift   On-device translation of committed lines through the Translation framework (macOS 15+)
    TranscriptionController.swift  Connects recognition events to the UI
  Views/                       ContentView, SettingsView, HistoryView, Theme; TranslationHost runs the translator's session on the main window
Sources/VoicedSimulate/        Development tool that drives the pipeline with an audio file (sources are symlinks)
Tests/VoicedTests/             Unit tests for the pure logic above
Scripts/                       App bundling and icon generation
Support/                       Info.plist and the app icon
```
