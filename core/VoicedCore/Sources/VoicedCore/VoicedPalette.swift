import SwiftUI

/// A single palette for native macOS and iOS views.
public enum VoicedPalette {
    public static let background = Color(red: 0.96, green: 0.96, blue: 0.94)
    /// Black: text, lines, sliders and toggles, and the fill of a pressed button.
    public static let accent = Color.black
    public static let accentDark = Color.black
    public static let aiAccent = Color(red: 0.58, green: 0.40, blue: 0.88)
    /// Speech that goes to the Mac: the light blue cards of sent lines and of the live text then.
    public static let macAccent = Color(red: 0.20, green: 0.52, blue: 0.92)
    /// Timestamps: a mid grey, a little darker than the light grey cards they sit on.
    public static let timestamp = Color(white: 0.45)
    public static let ink = Color(red: 0.18, green: 0.17, blue: 0.16)
    public static let rowFillOpacity: Double = 0.05
}
