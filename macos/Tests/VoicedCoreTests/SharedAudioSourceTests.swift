import XCTest
import WhisperKit
@testable import VoicedCore

final class SharedAudioSourceTests: XCTestCase {
    private final class Capture: AudioCapturing, @unchecked Sendable {
        var callback: (([Float]) -> Void)?
        var deviceID: DeviceID?
        var paused = false
        func start(deviceID: DeviceID?, onChunk: @escaping ([Float]) -> Void) throws { self.deviceID = deviceID; callback = onChunk }
        func pause() { paused = true }
        func resume() throws { paused = false }
        func stop() { callback = nil }
    }

    func testPlatformAdapterFeedsTheSharedBufferWithoutChangingSamples() throws {
        let capture = Capture()
        let source = MicrophoneAudioSource(capture: capture)
        var received: [Float] = []
        try source.startRecordingLive(inputDeviceID: nil) { received += $0 }
        let chunk = (0..<1600).map { Float($0 % 100) / 100 }
        capture.callback?(chunk)
        capture.callback?(chunk)
        XCTAssertEqual(Array(source.audioSamples), chunk + chunk)
        XCTAssertEqual(received, chunk + chunk)
        XCTAssertEqual(source.relativeEnergy.count, 2)
        source.purgeAudioSamples(keepingLast: 1600)
        XCTAssertEqual(Array(source.audioSamples), chunk)
        source.pauseRecording()
        XCTAssertTrue(capture.paused)
        try source.resumeRecordingLive(inputDeviceID: nil, callback: nil)
        XCTAssertFalse(capture.paused)
        source.stopRecording()
        XCTAssertNil(capture.callback)
    }

    func testMuteKeepsAudioTimingWithoutFeedingOutputBackIntoRecognition() throws {
        let capture = Capture()
        let mute = InputMute()
        mute.isMuted = true
        let source = MicrophoneAudioSource(capture: capture, mute: mute)
        try source.startRecordingLive(inputDeviceID: nil, callback: nil)
        capture.callback?([Float](repeating: 0.5, count: 1600))
        XCTAssertEqual(Array(source.audioSamples), [Float](repeating: 0, count: 1600))
        XCTAssertEqual(source.relativeEnergy, [0])
        source.stopRecording()
    }
}
