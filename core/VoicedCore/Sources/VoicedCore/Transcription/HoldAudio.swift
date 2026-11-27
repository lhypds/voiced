import Foundation
import SwiftUI

/// Keeps the session's captured audio from a chosen sample on, for transcribing holds as clips.
/// Without a hold only the last couple of seconds are kept, for the next hold's lead-in.
/// Fed on the transcriber's thread, read on the main actor.
public final class HoldAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    /// Samples received since the capture started.
    private var total = 0
    /// The earliest capture sample still needed; nil keeps only the lead-in.
    private var keepFrom: Int?
    private var samples: [Float] = []
    /// Capture index of `samples[0]`.
    private var samplesStart = 0
    /// Two seconds at Whisper's 16 kHz.
    private let leadIn = 2 * 16_000

    public init() {}

    public var count: Int { lock.withLock { total } }

    public func append(_ chunk: [Float]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            total += chunk.count
            trim()
        }
    }

    /// Keeps everything from capture sample `index` on (as far back as the lead-in reaches),
    /// unless an earlier start is already kept.
    public func keep(from index: Int) {
        lock.withLock {
            keepFrom = min(keepFrom ?? Int.max, max(0, index))
            trim()
        }
    }

    /// Back to keeping only a lead-in, once every clip has been taken.
    public func keepLeadInOnly() {
        lock.withLock {
            keepFrom = nil
            trim()
        }
    }

    /// The captured samples in `range`, as far as they are kept.
    public func clip(_ range: Range<Int>) -> [Float] {
        lock.withLock {
            let lower = max(0, range.lowerBound - samplesStart)
            let upper = min(samples.count, range.upperBound - samplesStart)
            return lower < upper ? Array(samples[lower..<upper]) : []
        }
    }

    private func trim() {
        let from = keepFrom ?? (total - leadIn)
        let drop = min(max(0, from - samplesStart), samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        samplesStart += drop
    }
}

/// The input's latest moment, for a waveform that shakes in place rather than scrolling, drawn
/// as lo's radio card draws its mirrored scope: the current samples reduced to columns, started
/// at a rising zero crossing so a steady sound stands still, tapered to the centre at both ends
/// and eased frame to frame so speech does not strobe. Fed on the capture thread, read per frame.
public final class WaveformMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [Float] = []
    private var columns: [CGFloat] = []
    /// About 128 ms at 16 kHz: half of it is drawn, the other half leaves room for the trigger.
    private static let window = 2048

    public init() {}

    public func push(_ chunk: [Float]) {
        lock.withLock {
            recent.append(contentsOf: chunk)
            if recent.count > Self.window * 2 { recent.removeFirst(recent.count - Self.window) }
        }
    }

    public func reset() {
        lock.withLock {
            recent = []
            columns = []
        }
    }

    /// The next frame: `count` amplitudes from 0 to 1, eased toward the current samples.
    public func frame(columns count: Int) -> [CGFloat] {
        lock.withLock {
            if columns.count != count { columns = Array(repeating: 0, count: count) }
            let samples = Array(recent.suffix(Self.window))
            let span = samples.count / 2
            guard span >= count, count > 1 else {
                for index in columns.indices { columns[index] *= 0.4 }
                return columns
            }
            var start = 0
            for index in 1..<(samples.count - span) where samples[index - 1] < 0 && samples[index] >= 0 {
                start = index
                break
            }
            let bucket = Double(span) / Double(count)
            for index in 0..<count {
                let from = start + Int(Double(index) * bucket)
                let to = max(from + 1, start + Int(Double(index + 1) * bucket))
                // The loudest sample in the column, not the average, which would flatten a consonant.
                let peak = samples[from..<to].reduce(Float(0)) { max($0, abs($1)) }
                // Microphone speech is far quieter than full scale: lifted so it fills the card.
                let target = CGFloat(pow(min(1, peak * 4), 0.7))
                let taper = CGFloat(pow(sin(Double(index) / Double(count - 1) * .pi), 0.35))
                columns[index] += (target * taper - columns[index]) * 0.6
            }
            return columns
        }
    }
}

/// The input's current waveform, shaking in place as lo's radio card does: mirrored around the
/// centre line, a faint fill under a thin trace, about thirty frames a second.
public struct WaveformView: View {
    let meter: WaveformMeter
    let color: Color

    public init(meter: WaveformMeter, color: Color) {
        self.meter = meter
        self.color = color
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                _ = timeline.date // Redrawn every frame.
                let columns = meter.frame(columns: max(24, min(128, Int(size.width / 2))))
                let mid = size.height / 2
                let reach = size.height * 0.45
                let step = size.width / CGFloat(columns.count - 1)
                let points = columns.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: max(0.02, $0.element) * reach) }
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: mid - points[0].y))
                for point in points { fill.addLine(to: CGPoint(x: point.x, y: mid - point.y)) }
                for point in points.reversed() { fill.addLine(to: CGPoint(x: point.x, y: mid + point.y)) }
                fill.closeSubpath()
                context.fill(fill, with: .color(color.opacity(0.22)))
                var trace = Path()
                trace.move(to: CGPoint(x: 0, y: mid - points[0].y))
                for point in points { trace.addLine(to: CGPoint(x: point.x, y: mid - point.y)) }
                context.stroke(trace, with: .color(color.opacity(0.72)),
                               style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
