import AVFoundation
import XCTest
@testable import Voiced

final class SessionRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicedTests.Recorder.\(UUID().uuidString)/1700000000", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        super.tearDown()
    }

    func testFileIsNamedAfterUnixSecondsOfStartInsideTheRecordDirectory() throws {
        let recorder = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date(timeIntervalSince1970: 1_700_000_000.9)))

        XCTAssertEqual(recorder.fileName, "1700000000.wav")
        XCTAssertEqual(recorder.fileURL.deletingLastPathComponent().path, directory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.fileURL.path), "the directory is created on demand")
        recorder.finish()
    }

    func testAudioIsWrittenAsSixteenKilohertzMonoWav() throws {
        let recorder = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date()))
        let first: [Float] = [0, 0.5, -0.5, 1, -1, 2, -2]
        let second = [Float](repeating: 0.25, count: 1_600)

        recorder.append(first)
        recorder.append([])
        recorder.append(second)
        XCTAssertTrue(recorder.finish())

        XCTAssertEqual(recorder.writtenSampleCount, first.count + second.count)
        let file = try AVAudioFile(forReading: recorder.fileURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Int(file.length), first.count + second.count)

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        XCTAssertEqual(samples[0], 0, accuracy: 0.001)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.001)
        XCTAssertEqual(samples[3], 1, accuracy: 0.001)
        XCTAssertEqual(samples[4], -1, accuracy: 0.001)
        XCTAssertEqual(samples[5], 1, accuracy: 0.001, "values above 1 are clipped")
        XCTAssertEqual(samples[6], -1, accuracy: 0.001)
        XCTAssertEqual(samples[100], 0.25, accuracy: 0.001)
    }

    func testFileStaysValidBeforeFinish() throws {
        let recorder = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date()))
        recorder.append([Float](repeating: 0.1, count: 3_200))

        // Not finished: the header must already describe the data written so far.
        let file = try AVAudioFile(forReading: recorder.fileURL)
        XCTAssertEqual(Int(file.length), 3_200)
        recorder.finish()
    }

    func testSessionWithoutAudioLeavesNoFile() throws {
        let recorder = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date()))

        XCTAssertFalse(recorder.finish())

        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "the record directory is left to the caller")
    }

    func testLaterSessionAppendsToTheRecordsFile() throws {
        let first = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        first.append([Float](repeating: 0.5, count: 1_600))
        XCTAssertTrue(first.finish())

        let second = try XCTUnwrap(SessionRecorder(appendingTo: "1700000000.wav", in: directory))
        XCTAssertEqual(second.fileName, "1700000000.wav")
        XCTAssertEqual(second.startOffset, 0.1, accuracy: 0.0001, "one tenth of a second was already in the file")
        second.append([Float](repeating: -0.25, count: 800))
        XCTAssertTrue(second.finish())

        let file = try AVAudioFile(forReading: second.fileURL)
        XCTAssertEqual(Int(file.length), 2_400)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        XCTAssertEqual(samples[1_599], 0.5, accuracy: 0.001)
        XCTAssertEqual(samples[1_600], -0.25, accuracy: 0.001)
        XCTAssertEqual(samples[2_399], -0.25, accuracy: 0.001)
    }

    func testAppendedSessionWithoutAudioKeepsTheFile() throws {
        let first = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        first.append([Float](repeating: 0.5, count: 1_600))
        first.finish()

        let second = try XCTUnwrap(SessionRecorder(appendingTo: "1700000000.wav", in: directory))
        XCTAssertFalse(second.finish())

        XCTAssertEqual(try Int(AVAudioFile(forReading: second.fileURL).length), 1_600)
    }

    func testAppendingNeedsAFileThisRecorderWrote() throws {
        XCTAssertNil(SessionRecorder(appendingTo: "missing.wav", in: directory))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: directory.appendingPathComponent("junk.wav"))
        XCTAssertNil(SessionRecorder(appendingTo: "junk.wav", in: directory))
    }

    func testSessionsStartedInTheSameSecondGetDistinctFiles() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: startedAt))
        let second = try XCTUnwrap(SessionRecorder(directory: directory, startedAt: startedAt.addingTimeInterval(0.5)))

        XCTAssertEqual(first.fileName, "1700000000.wav")
        XCTAssertEqual(second.fileName, "1700000000-2.wav")
        first.finish()
        second.finish()
    }
}
