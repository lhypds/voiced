import SwiftUI

/// Input RMS on a log scale. With a threshold, a marker sits at the energy floor and the bar fills
/// in the accent colour only once the level clears it, so the user can see when audio would be
/// decoded; without one, the bar is always in the accent colour.
public struct LevelMeter: View {
    let level: Float
    var threshold: Float?

    public init(level: Float, threshold: Float? = nil) {
        self.level = level
        self.threshold = threshold
    }

    private static let floor: Float = 0.001
    private static let ceiling: Float = 0.5

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let levelX = width * CGFloat(Self.position(of: level))
            let clearsThreshold = threshold.map { level >= $0 } ?? true
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(VoicedPalette.accent.opacity(VoicedPalette.rowFillOpacity))
                Capsule()
                    .fill(clearsThreshold ? VoicedPalette.accent : Color.secondary.opacity(0.5))
                    .frame(width: max(0, levelX))
                    .animation(.linear(duration: 0.1), value: level)
            }
            // The marker pokes past the bar on each side so it reads as a line across it rather
            // than a notch in it. As an overlay it leaves the bar's layout size alone; as a stack
            // child it would stretch the stack to its own height and push the bar off centre.
            .overlay(alignment: .leading) {
                if let threshold {
                    Rectangle()
                        .fill(VoicedPalette.accentDark)
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: width * CGFloat(Self.position(of: threshold)) - 1)
                }
            }
        }
    }

    private static func position(of value: Float) -> Float {
        let clamped = min(max(value, floor), ceiling)
        return (log10(clamped) - log10(floor)) / (log10(ceiling) - log10(floor))
    }
}
