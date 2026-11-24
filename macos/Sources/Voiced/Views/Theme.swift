import VoicedCore
import AppKit
import SwiftUI

/// Shared colours and spacing so the views agree on a single palette.
enum Theme {
    static let background = VoicedPalette.background
    /// Light orange used for the record button and timestamps.
    static let accent = VoicedPalette.accent
    /// Darker orange for the record button's lower edge and shadow.
    static let accentDark = VoicedPalette.accentDark
    /// Purple for everything the AI service produces: the AI settings page and the hint bubbles.
    static let aiAccent = VoicedPalette.aiAccent

    static let contentPadding: CGFloat = 22
    static let rowSpacing: CGFloat = 22
    /// Vertical gap between transcript rows, and between the LIVE box and the first row.
    static let rowGap: CGFloat = 10
    /// Opacity of the accent colour behind every transcript row and the LIVE box.
    static let rowFillOpacity = VoicedPalette.rowFillOpacity
    /// Stronger fill while the pointer is over a row, so the click-to-copy target is clear.
    static let rowFillHoverOpacity: Double = 0.26
    static let bodyFontSize: CGFloat = 17
    /// Size of the second text of a translated row, under the main one.
    static let secondaryFontSize: CGFloat = 14
    /// Size of the AI's hints: a little under the transcript's text, as they say more per row.
    static let hintFontSize: CGFloat = 15
    /// Gap between a row's main text and its second text.
    static let secondaryTextGap: CGFloat = 4
    /// Height of one line of body text; the lower bound for the timestamp column height.
    static let bodyLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: bodyFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    /// Spacing between the stacked date and time lines in the timestamp column.
    static let timestampLineSpacing: CGFloat = 2
    /// Fixed height of the left column (LIVE, time, or date + time) so every row has the same
    /// height regardless of which label it shows. Sized to fit the two-line date + time case.
    static let timestampColumnHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        let line = ceil(font.ascender - font.descender + font.leading)
        return max(bodyLineHeight, line * 2 + timestampLineSpacing)
    }()
}
