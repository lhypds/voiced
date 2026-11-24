import XCTest
@testable import VoicedCore
import WhisperKit

final class VoiceDetectorTests: XCTestCase {
    private let rate = 16_000
    private let chunk = VoiceActivity.chunkLength
    private let floor: Float = 0.02

    func testRangeIsSpeechWhenAnyOverlappingChunkIs() {
        var activity = VoiceActivity()
        activity.append([false, false, true, false])

        XCTAssertTrue(activity.containsSpeech(in: (2 * chunk - 1)..<(2 * chunk + 1)), "touches the first sample of the speech chunk")
        XCTAssertTrue(activity.containsSpeech(in: (3 * chunk - 1)..<(4 * chunk)), "touches its last sample")
        XCTAssertFalse(activity.containsSpeech(in: (3 * chunk)..<(4 * chunk)))
    }

    func testRangeShortlyBeforeSpeechCountsAsItsOnset() {
        let lag = VoiceActivity.onsetLagChunks
        var activity = VoiceActivity()
        activity.append([Bool](repeating: false, count: lag + 2) + [true])

        XCTAssertTrue(activity.containsSpeech(in: (2 * chunk)..<(3 * chunk)), "the speech chunk is within the lag after it")
        XCTAssertFalse(activity.containsSpeech(in: chunk..<(2 * chunk)), "the speech chunk is past the lag")
    }

    func testAudioNoChunkHasJudgedYetCountsAsSpeech() {
        var activity = VoiceActivity()
        XCTAssertTrue(activity.containsSpeech(in: 0..<100), "nothing judged yet")

        activity.append([false])

        XCTAssertTrue(activity.containsSpeech(in: chunk..<(chunk + 100)), "past the last judged chunk")
        XCTAssertFalse(activity.containsSpeech(in: (chunk - 10)..<(chunk + 100)), "a judged quiet chunk overlaps")
        XCTAssertFalse(activity.containsSpeech(in: 5..<5))
    }

    func testDiscardKeepsLaterChunksInPlace() {
        let lag = VoiceActivity.onsetLagChunks
        var activity = VoiceActivity()
        activity.append([true] + [Bool](repeating: false, count: lag + 1) + [true])

        activity.discard(before: chunk + 10)

        XCTAssertEqual(activity.start, chunk, "only the first chunk ends before the cut")
        XCTAssertEqual(activity.chunks, [Bool](repeating: false, count: lag + 1) + [true])
        XCTAssertFalse(activity.containsSpeech(in: chunk..<(2 * chunk)))
        XCTAssertTrue(activity.containsSpeech(in: ((lag + 2) * chunk)..<((lag + 3) * chunk)))

        activity.discard(before: 100 * chunk)

        XCTAssertEqual(activity.chunks, [])
        XCTAssertEqual(activity.start, (lag + 3) * chunk)
    }

    func testDecodeInputSkipsLoudAudioTheDetectorRejects() {
        // 2 s of tone; the detector hears speech only from chunk 31 (0.992 s) on, which makes chunk
        // 21 (0.672 s) the onset, so the first speech frame is the 100 ms frame starting at 0.6 s,
        // and half a second before it is kept.
        let buffer = tone(2)
        var activity = VoiceActivity()
        activity.append([Bool](repeating: false, count: 31) + [Bool](repeating: true, count: 40))

        let (samples, lead) = LiveTranscriber.decodeInput(buffer, floor: floor, voice: activity, captureOffset: 0)

        XCTAssertEqual(lead, 0.1, accuracy: 0.001)
        XCTAssertEqual(samples.count, Int(1.9 * Float(rate)))
    }

    func testDecodeInputPlacesTheBufferByItsCaptureOffset() {
        // The same verdicts, but the buffer starts where the speech chunks begin.
        let buffer = tone(2)
        var activity = VoiceActivity()
        activity.append([Bool](repeating: false, count: 31) + [Bool](repeating: true, count: 40))

        let (samples, lead) = LiveTranscriber.decodeInput(buffer, floor: floor, voice: activity, captureOffset: 31 * chunk)

        XCTAssertEqual(lead, 0)
        XCTAssertEqual(samples.count, buffer.count)
    }

    /// Runs the real model when it is in the cache (turn the voice filter on in the app once, or
    /// run `VoicedSimulate --vad`); skipped otherwise.
    func testModelHearsSpeechAndNotSilence() throws {
        guard let folder = VoiceDetectorModelStore.cachedModelFolder() else {
            throw XCTSkip("voice detector model not cached")
        }
        let detector = try SileroVoiceDetector(modelFolder: folder)

        let silence = try detector.process([Float](repeating: 0, count: rate))
        XCTAssertEqual(silence.count, rate / chunk, "one verdict per full chunk")
        XCTAssertLessThan(silence.max() ?? 1, SileroVoiceDetector.speechThreshold)

        try detector.reset()
        let speech = try detector.process(try spokenSample())
        let heard = speech.filter { $0 >= SileroVoiceDetector.speechThreshold }.count
        XCTAssertGreaterThan(heard, speech.count / 2, "most chunks of a spoken sentence are speech")
    }

    /// A sentence spoken by the system voice, at 16 kHz.
    private func spokenSample() throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "voiced-vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEI16@16000", "This is a short sentence for the voice detector."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say is not available") }
        return AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: file.path))
    }

    private func tone(_ seconds: Float) -> ContiguousArray<Float> {
        ContiguousArray((0..<Int(seconds * Float(rate))).map { 0.3 * sin(Float($0) * 2 * .pi * 440 / Float(rate)) })
    }
}
