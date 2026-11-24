import SwiftUI

/// A round button drawn as a thin ring with the symbol in ink. It fills with ink, the symbol
/// turning white, only while it is pressed (or while `held` says it is being held down).
public struct RingButtonStyle: ButtonStyle {
    public var size: CGFloat
    public var symbolSize: CGFloat?
    public var lineWidth: CGFloat
    public var held: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 44, symbolSize: CGFloat? = nil, lineWidth: CGFloat = 1.5, held: Bool = false) {
        self.size = size
        self.symbolSize = symbolSize
        self.lineWidth = lineWidth
        self.held = held
    }

    public func makeBody(configuration: Configuration) -> some View {
        let filled = configuration.isPressed || held
        return configuration.label
            .font(.system(size: symbolSize ?? size * 0.4, weight: .regular))
            .foregroundStyle(filled ? Color.white : VoicedPalette.accent)
            .tint(filled ? Color.white : VoicedPalette.accent)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(filled ? VoicedPalette.accent : Color.clear)
                    Circle().strokeBorder(VoicedPalette.accent, lineWidth: lineWidth)
                }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: filled)
    }
}
