// Development tool: feeds a 16 kHz speech file through LiveTranscriber at real-time pace, mirrors the
// app's commit logic and verifies that pauses finalize the live sentence, committed lines never change
// and the raw audio handed to the session recorder is exactly what was fed in.
//
//   say -v Kyoko -o sample.wav --data-format=LEI16@16000 "こんにちは [[slnc 3000]] さようなら"
//   swift run -c release VoicedSimulate sample.wav --lang ja [--engine accurate] [--noise 0.02] [--denoise] [--floor 0.01] [--energy]
import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Plays a 16 kHz mono file into the pipeline as if it were a microphone, then feeds silence.
final class FileAudioSource: AudioProcessing, @unchecked Sendable {
    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }
    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }
    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }
    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: false)
    }

    private let lock = NSLock()
    private var samples = ContiguousArray<Float>()
    /// Everything ever appended to the buffer, for checking the transcriber's audio sink.
    private var fed: [Float] = []
    private var energy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    private let source: [Float]
    private var cursor = 0
    private var timer: DispatchSourceTimer?
    private let chunk = 1600 // 100 ms at 16 kHz
    var relativeEnergyWindow: Int = 20
    private(set) var fedSeconds: Float = 0

    /// `denoise` runs the file through spectral subtraction first, with a profile measured from
    /// 2 seconds of fresh noise at the same amplitude, the way the app measures the room.
    init(file: String, noise: Float, denoise: Bool) throws {
        let buffer = try AudioProcessor.loadAudio(fromPath: file)
        var samples = AudioProcessor.convertBufferToArray(buffer: buffer)
        if noise > 0 {
            for i in samples.indices { samples[i] = max(-1, min(1, samples[i] + Float.random(in: -noise...noise))) }
        }
        if denoise {
            let room = (0..<32_000).map { _ in Float.random(in: -noise...noise) }
            guard let profile = NoiseProfile(noise: room) else { fatalError("could not build noise profile") }
            samples = SpectralDenoiser.denoise(samples, profile: profile)
        }
        source = samples
    }

    var audioSamples: ContiguousArray<Float> { lock.withLock { samples } }
    var fedSamples: [Float] { lock.withLock { fed } }
    var relativeEnergy: [Float] { lock.withLock { energy.map(\.rel) } }

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.withLock { if samples.count > keep { samples.removeFirst(samples.count - keep) } }
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sim.audio"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [self] in
            let end = min(cursor + chunk, source.count)
            var buffer = cursor < source.count ? Array(source[cursor..<end]) : []
            cursor = end
            if buffer.count < chunk { buffer.append(contentsOf: [Float](repeating: 0, count: chunk - buffer.count)) }
            lock.withLock {
                samples.append(contentsOf: buffer)
                fed.append(contentsOf: buffer)
                let minAvg = energy.suffix(20).reduce(Float.infinity) { min($0, $1.avg) }
                let rel = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: minAvg)
                let e = AudioProcessor.calculateEnergy(of: buffer)
                energy.append((rel, e.avg, e.max, e.min))
                fedSeconds += 0.1
            }
        }
        timer.resume()
        self.timer = timer
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        AsyncThrowingStream.makeStream(of: [Float].self)
    }
    func pauseRecording() { timer?.suspend() }
    func stopRecording() { timer?.cancel(); timer = nil }
    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws { timer?.resume() }

    var sourceSeconds: Float { Float(source.count) / 16_000 }
}

let file = CommandLine.arguments.dropFirst().first ?? ""
guard !file.isEmpty else { fatalError("usage: VoicedSimulate <speech.wav> [--energy]") }

if CommandLine.arguments.contains("--energy") {
    // Dump the per-100 ms energy values the VAD sees, without loading the model.
    let buffer = try AudioProcessor.loadAudio(fromPath: file)
    let source = AudioProcessor.convertBufferToArray(buffer: buffer)
    var history: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    var index = 0
    while index < source.count {
        let chunk = Array(source[index..<min(index + 1600, source.count)])
        let minAvg = history.suffix(20).reduce(Float.infinity) { min($0, $1.avg) }
        let rel = AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: minAvg)
        let e = AudioProcessor.calculateEnergy(of: chunk)
        history.append((rel, e.avg, e.max, e.min))
        print(String(format: "%5.1fs rel=%.2f avg=%.5f max=%.3f %@", Float(index) / 16_000, rel, e.avg, e.max, rel > 0.12 ? "VOICE" : "-"))
        index += 1600
    }
    exit(0)
}
let started = Date()
@Sendable func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(started)) }

let engineIndex = CommandLine.arguments.firstIndex(of: "--engine")
let engine = engineIndex.flatMap { RecognitionEngine(rawValue: CommandLine.arguments[$0 + 1]) } ?? .turbo
print("loading \(engine.rawValue) model...")
guard let folder = WhisperModelStore.cachedModelFolder(for: engine) else { fatalError("\(engine.rawValue) model not cached") }
let loadStarted = Date()
let whisperKit = try await WhisperModelStore.load(modelFolder: folder) { component in
    print(String(format: "loading component %d: %@", component.rawValue + 1, String(describing: component)))
}
print(String(format: "model loaded in %.1fs", Date().timeIntervalSince(loadStarted)))
let noiseIndex = CommandLine.arguments.firstIndex(of: "--noise")
let noise = noiseIndex.flatMap { Float(CommandLine.arguments[$0 + 1]) } ?? 0
let audio = try FileAudioSource(file: file, noise: noise, denoise: CommandLine.arguments.contains("--denoise"))
print("model ready; feeding \(audio.sourceSeconds)s of audio")

let langIndex = CommandLine.arguments.firstIndex(of: "--lang")
let language = langIndex.map { CommandLine.arguments[$0 + 1] } ?? "en"
let floorIndex = CommandLine.arguments.firstIndex(of: "--floor")
let speechEnergyFloor = floorIndex.flatMap { Float(CommandLine.arguments[$0 + 1]) } ?? LiveTranscriber.defaultSpeechEnergyFloor
let promptIndex = CommandLine.arguments.firstIndex(of: "--prompt-file")
let promptText = promptIndex.flatMap { RecognitionPrompt.load(from: URL(fileURLWithPath: CommandLine.arguments[$0 + 1])) }
let promptTokens = whisperKit.tokenizer.flatMap { RecognitionPrompt.tokens(for: promptText, tokenizer: $0) }
if let promptText { print("prompt (\(promptTokens?.count ?? 0) tokens): \(promptText)") }
let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 1, usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true, promptTokens: promptTokens, logProbThreshold: -0.8, noSpeechThreshold: 0.4)
let assembler = SentenceAssembler(languageCode: language)
var session = RecordingSession(startedAt: started, baseLines: [])
var liveText = ""
var transcriptHistory: [[String]] = []
var silenceCommits = 0
var failures: [String] = []
var lastFinishedDecode = 0
var replacementCharacterHits = 0

func lines(from segments: [TranscriptionSegment]) -> [TranscriptLine] {
    segments.compactMap { seg in
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptLine(id: "\(seg.id)-\(seg.start)-\(seg.end)", start: seg.start, end: seg.end, recordedAt: started, text: text)
    }
}
@MainActor func record(_ reason: String) {
    let transcript = session.transcript.map(\.text)
    if let previous = transcriptHistory.last, !transcript.starts(with: previous) {
        failures.append("committed lines changed at \(stamp()): \(previous) -> \(transcript)")
    }
    transcriptHistory.append(transcript)
    print("\(stamp()) [\(reason)] transcript=\(transcript) live=\"\(liveText)\" committedEnd=\(session.committedEnd)")
}

@MainActor final class Driver: LiveTranscriberDelegate {
    func transcriber(_ transcriber: LiveTranscriber, didUpdateLiveText text: String, decode: Int) {
        guard decode > lastFinishedDecode, !session.pendingLines.isEmpty else { return }
        if text.contains("\u{FFFD}") {
            replacementCharacterHits += 1
            if replacementCharacterHits <= 3 { print("\(stamp()) live text with U+FFFD: \"\(text.suffix(30))\"") }
        }
        let trimmed = HallucinationFilter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { liveText = assembler.normalized(trimmed) }
    }
    func transcriber(_ transcriber: LiveTranscriber, didDecode segments: [TranscriptionSegment], decode: Int) -> Float {
        lastFinishedDecode = decode
        for segment in segments where segment.text.contains("\u{FFFD}") {
            replacementCharacterHits += 1
            print("\(stamp()) segment with U+FFFD: \"\(segment.text)\"")
        }
        let segmentLines = lines(from: segments)
        _ = session.update(latest: assembler.sentences(from: segmentLines), completed: assembler.sentences(from: segmentLines, includeTrailing: false))
        liveText = assembler.draft(from: session.pendingLines.map(\.text))
        print("\(stamp()) decoded: \(segments.map { String(format: "[%.1f-%.1f lp=%.2f] %@", $0.start, $0.end, $0.avgLogprob, $0.text.trimmingCharacters(in: .whitespaces)) })")
        record("decoded")
        return session.committedEnd
    }
    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) -> Float {
        silenceCommits += 1
        let committed = session.commitTrailing(finalize: assembler.terminated)
        liveText = ""
        record(committed ? "PAUSE committed pending sentence" : "pause, nothing pending")
        return session.committedEnd
    }
    func transcriber(_ transcriber: LiveTranscriber, didFailWith error: Error) {
        failures.append("stream failed: \(error.localizedDescription)")
    }
}

/// Collects what the transcriber hands to the audio sink, the way `SessionRecorder` would write it.
final class CapturedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ new: [Float]) { lock.withLock { samples.append(contentsOf: new) } }
    var all: [Float] { lock.withLock { samples } }
}
let captured = CapturedAudio()

let driver = Driver()
let transcriber = LiveTranscriber(whisperKit: whisperKit, options: options, inputDeviceID: 0, silenceThreshold: 0.12, silenceDelay: 2, speechEnergyFloor: speechEnergyFloor, delegate: driver, audioProcessor: audio, audioSink: { captured.append($0) }, log: { message in
    print("\(stamp()) LT fed=\(String(format: "%.1f", audio.fedSeconds))s \(message)")
})

try await transcriber.start()
try? await Task.sleep(for: .seconds(TimeInterval(audio.sourceSeconds) + 5))
await transcriber.stop()
try? await Task.sleep(for: .seconds(1))
session.commitTrailing(finalize: assembler.terminated)
print("\nFINAL transcript: \(session.transcript.map(\.text))")
print("silence commits: \(silenceCommits)")
let capturedSamples = captured.all
let fedSamples = audio.fedSamples
print("captured audio: \(Float(capturedSamples.count) / 16_000)s of \(Float(fedSamples.count) / 16_000)s fed")
if capturedSamples.count < Int(audio.sourceSeconds * 16_000) { failures.append("audio sink missed the end of the file") }
if !fedSamples.starts(with: capturedSamples) { failures.append("audio sink received samples out of order, duplicated or skipped") }
print("texts containing U+FFFD: \(replacementCharacterHits)")
if replacementCharacterHits > 0 { failures.append("replacement characters reached the UI") }
if silenceCommits < 1 { failures.append("expected at least one pause event, got \(silenceCommits)") }
if session.transcript.count < 2 { failures.append("expected at least two committed lines") }
print(failures.isEmpty ? "SIMULATION PASSED" : "SIMULATION FAILED:\n  " + failures.joined(separator: "\n  "))
exit(failures.isEmpty ? 0 : 1)
