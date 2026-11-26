import SwiftUI

/// A round button drawn as a thin ring with the symbol in ink. It fills with ink, the symbol
/// turning white, only while it is pressed (or while `held` says it is being held down).
public struct RingButtonStyle: ButtonStyle {
    public var size: CGFloat
    public var symbolSize: CGFloat?
    public var lineWidth: CGFloat
    public var held: Bool
    /// The ring, the symbol, and the fill while pressed.
    public var color: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 44, symbolSize: CGFloat? = nil, lineWidth: CGFloat = 1.5, held: Bool = false, color: Color = VoicedPalette.accent) {
        self.size = size
        self.symbolSize = symbolSize
        self.lineWidth = lineWidth
        self.held = held
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        let filled = configuration.isPressed || held
        return configuration.label
            .font(.system(size: symbolSize ?? size * 0.4, weight: .regular))
            .foregroundStyle(filled ? Color.white : color)
            .tint(filled ? Color.white : color)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(filled ? color : Color.clear)
                    Circle().strokeBorder(color, lineWidth: lineWidth)
                }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: filled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: color)
    }
}
