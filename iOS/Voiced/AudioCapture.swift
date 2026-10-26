import AVFoundation
import Foundation
import VoicedCore
import WhisperKit

/// iOS only owns the audio session and conversion. The shared MicrophoneAudioSource
/// owns sample buffering, energy calculation, denoising and delivery to recognition.
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var started = false
    private var sessionActive = false

    func start(deviceID: DeviceID?, onChunk: @escaping ([Float]) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        sessionActive = true
        do {
            if let deviceID {
                guard let port = session.availableInputs?.first(where: { $0.uid == deviceID }) else {
                    throw NSError(domain: "Voiced", code: 4, userInfo: [NSLocalizedDescriptionKey: "所选音频输入已断开，请重新选择设备。"])
                }
                try session.setPreferredInput(port)
            }
            let input = engine.inputNode
            let source = input.outputFormat(forBus: 0)
            guard source.sampleRate > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: target) else {
                throw NSError(domain: "Voiced", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法初始化麦克风音频格式。"])
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / source.sampleRate)) + 32
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                guard error == nil, let channel = output.floatChannelData?[0] else { return }
                onChunk(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            do { try engine.start(); started = true }
            catch { input.removeTap(onBus: 0); throw error }
        } catch { stop(); throw error }
    }

    func pause() { engine.pause() }
    func resume() throws { try engine.start() }

    func stop() {
        if started {
            started = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
