import Foundation

/// Software gain applied by each platform's capture adapter to every chunk it delivers, so
/// recognition, metering, noise calibration and recordings all hear the same level. Read on the
/// capture thread and changed from Settings while capture runs.
public final class InputGain: @unchecked Sendable {
    public static let shared = InputGain()
    /// Decibels the Settings slider spans; 0 dB, in the middle, leaves the input as it is.
    public static let range: ClosedRange<Float> = -20...20

    private let lock = NSLock()
    private var factor: Float = 1

    public init() {}

    public var decibels: Float {
        get { lock.withLock { 20 * log10(factor) } }
        set { lock.withLock { factor = pow(10, min(max(newValue, Self.range.lowerBound), Self.range.upperBound) / 20) } }
    }

    /// Scales the chunk, clipping at full scale so a boosted peak does not wrap around.
    public func apply(_ chunk: [Float]) -> [Float] {
        let factor = lock.withLock { self.factor }
        guard factor != 1 else { return chunk }
        return chunk.map { min(max($0 * factor, -1), 1) }
    }
}
