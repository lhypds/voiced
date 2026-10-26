import WhisperKit

/// Platform adapters only deliver 16 kHz mono chunks; buffering, energy, denoising and
/// recognition belong to the shared pipeline. The callback runs on the capture thread.
public protocol AudioCapturing: AnyObject, Sendable {
    func start(deviceID: DeviceID?, onChunk: @escaping ([Float]) -> Void) throws
    func pause()
    func resume() throws
    func stop()
}
