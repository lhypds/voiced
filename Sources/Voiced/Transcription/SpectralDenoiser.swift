import Accelerate
import Foundation

/// Fingerprint of the background noise: the average magnitude of each frequency bin, measured
/// over a recording made while nobody was speaking. `SpectralDenoiser` subtracts it from live audio.
struct NoiseProfile: Equatable, Sendable {
    /// Magnitude per bin, `SpectralDenoiser.binCount` entries from DC to Nyquist, in the packed
    /// scale `SpectralDenoiser` uses for its own spectra.
    let magnitudes: [Float]

    /// Averages the spectra of all full frames in `noise`. Nil when there is less than one frame.
    init?(noise: [Float]) {
        let analyzer = SpectralDenoiser.Spectrum()
        var sum = [Float](repeating: 0, count: SpectralDenoiser.binCount)
        var frames = 0
        var start = 0
        while start + SpectralDenoiser.frameLength <= noise.count {
            let magnitudes = analyzer.magnitudes(of: Array(noise[start..<start + SpectralDenoiser.frameLength]))
            vDSP.add(sum, magnitudes, result: &sum)
            frames += 1
            start += SpectralDenoiser.hopLength
        }
        guard frames > 0 else { return nil }
        magnitudes = vDSP.divide(sum, Float(frames))
    }

    /// Restores a profile saved with `stored`; nil when the bin count does not match.
    init?(stored: [Double]) {
        guard stored.count == SpectralDenoiser.binCount else { return nil }
        magnitudes = stored.map(Float.init)
    }

    var stored: [Double] { magnitudes.map(Double.init) }
}

/// Streaming spectral subtraction: each frame of audio is moved to the frequency domain, the noise
/// profile is taken off every bin's magnitude, and the frame is rebuilt with its original phase.
/// Frames overlap by half and are windowed on both analysis and synthesis, so the output is seamless.
///
/// Call `process` with audio in any chunk sizes; the output comes in multiples of the hop length and
/// lags the input by one to two hops (16 to 32 ms). Not thread-safe: call it from one thread at a time.
final class SpectralDenoiser {
    static let frameLength = 512
    static let hopLength = frameLength / 2
    static let binCount = frameLength / 2 + 1
    /// Default over-subtraction factor: how many times the measured noise is removed. Values above 1
    /// take care of noise that is momentarily louder than its average.
    static let defaultStrength: Float = 2
    /// Lowest gain applied to any bin, so subtraction never zeroes a bin outright; that is what
    /// turns residual noise into "musical" chirps.
    private static let minimumGain: Float = 0.1
    /// Weight of the previous frame's gain in the current one; smooths the gain over time, which
    /// also suppresses musical noise.
    private static let gainMemory: Float = 0.3

    /// Multiplier on the noise profile before subtraction.
    var strength: Float
    private let noise: [Float]
    private let spectrum = Spectrum()
    private var pending: [Float]
    /// Second half of the last synthesized frame, still to be summed with the next frame's first half.
    private var overlap = [Float](repeating: 0, count: SpectralDenoiser.hopLength)
    private var previousGain = [Float](repeating: 1, count: SpectralDenoiser.binCount)
    /// Frames are primed with half a frame of silence so the first real samples get full window
    /// weight; the silence itself is not emitted.
    private var primed = false

    init(profile: NoiseProfile, strength: Float = SpectralDenoiser.defaultStrength) {
        noise = profile.magnitudes
        self.strength = strength
        pending = [Float](repeating: 0, count: Self.hopLength)
    }

    /// Denoises a complete recording in one go. The output has the same length as the input.
    static func denoise(_ samples: [Float], profile: NoiseProfile) -> [Float] {
        let denoiser = SpectralDenoiser(profile: profile)
        return denoiser.process(samples) + denoiser.flush()
    }

    /// Denoises `samples`, returning every hop that became complete.
    func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var output: [Float] = []
        output.reserveCapacity(pending.count)
        while pending.count >= Self.frameLength {
            let frame = spectrum.filtered(Array(pending[0..<Self.frameLength]), gain: gain)
            pending.removeFirst(Self.hopLength)
            if primed {
                output.append(contentsOf: vDSP.add(overlap, frame[0..<Self.hopLength]))
            } else {
                primed = true
            }
            overlap = Array(frame[Self.hopLength...])
        }
        return output
    }

    /// Emits every sample still inside the pipeline, padding the last frame with silence. Call once at the end.
    func flush() -> [Float] {
        // Everything pending is owed: the half frame waiting in `overlap` plus any unframed tail.
        // Before priming, the pending buffer still holds the silent half frame, which is not.
        let owed = primed ? pending.count : pending.count - Self.hopLength
        guard owed > 0 else { return [] }
        let output = process([Float](repeating: 0, count: Self.frameLength))
        return Array(output.prefix(owed))
    }

    /// Gain for each bin given the frame's magnitudes: what is left after subtracting the noise,
    /// as a fraction of the original, never below `minimumGain`, smoothed against the previous frame.
    private func gain(for magnitudes: [Float]) -> [Float] {
        var gain = [Float](repeating: 1, count: Self.binCount)
        for bin in 0..<Self.binCount {
            let magnitude = magnitudes[bin]
            let target: Float
            if magnitude > 0 {
                target = max((magnitude - strength * noise[bin]) / magnitude, Self.minimumGain)
            } else {
                target = Self.minimumGain
            }
            gain[bin] = Self.gainMemory * previousGain[bin] + (1 - Self.gainMemory) * target
        }
        previousGain = gain
        return gain
    }

    /// Real FFT of one frame via vDSP, with the window applied on the way in and out.
    /// The packed layout keeps the Nyquist value in `imaginary[0]`.
    final class Spectrum {
        private let log2n = vDSP_Length(log2(Double(SpectralDenoiser.frameLength)))
        private let setup: FFTSetup
        /// Square-root Hann: applied twice (analysis and synthesis) it becomes a Hann window, which
        /// sums to one across half-overlapping frames.
        private let window: [Float]
        private var real = [Float](repeating: 0, count: SpectralDenoiser.hopLength)
        private var imaginary = [Float](repeating: 0, count: SpectralDenoiser.hopLength)

        init() {
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: SpectralDenoiser.frameLength, isHalfWindow: false)
                .map { $0.squareRoot() }
        }

        deinit {
            vDSP_destroy_fftsetup(setup)
        }

        /// Magnitude of each bin of the windowed frame.
        func magnitudes(of frame: [Float]) -> [Float] {
            forward(frame)
            return packedMagnitudes()
        }

        /// The windowed frame with each bin scaled by `gain(magnitudes)`, back in the time domain
        /// and windowed again for overlap-add.
        func filtered(_ frame: [Float], gain: ([Float]) -> [Float]) -> [Float] {
            forward(frame)
            let gain = gain(packedMagnitudes())
            real[0] *= gain[0]
            imaginary[0] *= gain[SpectralDenoiser.binCount - 1]
            for bin in 1..<SpectralDenoiser.hopLength {
                real[bin] *= gain[bin]
                imaginary[bin] *= gain[bin]
            }
            return inverse()
        }

        private func forward(_ frame: [Float]) {
            let windowed = vDSP.multiply(frame, window)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { windowedPointer in
                        windowedPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: SpectralDenoiser.hopLength) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(SpectralDenoiser.hopLength))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        private func inverse() -> [Float] {
            var output = [Float](repeating: 0, count: SpectralDenoiser.frameLength)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    output.withUnsafeMutableBufferPointer { outputPointer in
                        outputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: SpectralDenoiser.hopLength) { complexPointer in
                            vDSP_ztoc(&split, 1, complexPointer, 2, vDSP_Length(SpectralDenoiser.hopLength))
                        }
                    }
                }
            }
            // A forward and inverse zrip pass scales the signal by 2 × frameLength.
            let scale = 1 / Float(2 * SpectralDenoiser.frameLength)
            return vDSP.multiply(scale, vDSP.multiply(output, window))
        }

        /// Magnitudes in bin order: DC, bins 1..<hop, Nyquist.
        private func packedMagnitudes() -> [Float] {
            var magnitudes = [Float](repeating: 0, count: SpectralDenoiser.binCount)
            magnitudes[0] = abs(real[0])
            magnitudes[SpectralDenoiser.binCount - 1] = abs(imaginary[0])
            for bin in 1..<SpectralDenoiser.hopLength {
                magnitudes[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
            }
            return magnitudes
        }
    }
}
