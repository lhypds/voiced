import Foundation

/// Makes the punctuation of recognized text match its script.
///
/// Whisper mixes half-width and full-width marks freely. Chinese and Japanese text is rewritten
/// with full-width marks (Japanese clauses end with 、, Chinese clauses with ，), and everything
/// else with ASCII marks followed by a space.
public enum PunctuationNormalizer {
    public enum Script: Equatable {
        case chinese
        case japanese
        case latin
    }

    /// Script decided from the characters of `text`. Kana means Japanese; Han characters alone mean
    /// Japanese only when `languageCode` is "ja", otherwise Chinese. Anything else is Latin.
    public static func script(of text: String, languageCode: String?) -> Script {
        var sawHan = false
        for scalar in text.unicodeScalars {
            if isKana(scalar) { return .japanese }
            if isHan(scalar) { sawHan = true }
        }
        if sawHan { return languageCode == "ja" ? .japanese : .chinese }
        return .latin
    }

    public static func normalize(_ text: String, languageCode: String?) -> String {
        switch script(of: text, languageCode: languageCode) {
        case .latin: return halfWidth(text)
        case .chinese: return fullWidth(text, comma: "，")
        case .japanese: return fullWidth(text, comma: "、")
        }
    }

    // MARK: - Full width

    private static let fullWidthMarks: [Character: Character] = [
        "!": "！", "?": "？", ":": "：", ";": "；", "(": "（", ")": "）",
    ]

    private static func fullWidth(_ text: String, comma: Character) -> String {
        let chars = Array(text)
        var out = ""
        var skipSpaces = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if skipSpaces, c == " " {
                i += 1
                continue
            }
            skipSpaces = false
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil

            if c == ".", next == "." {
                // An ASCII ellipsis becomes the CJK one.
                while i < chars.count, chars[i] == "." { i += 1 }
                out.append("……")
                skipSpaces = true
                continue
            }
            if isInsideASCIIWord(prev, next) {
                // Keep marks inside numbers and Latin words, as in 3.14 or 1,000.
                out.append(c)
                i += 1
                continue
            }

            let replacement: Character?
            switch c {
            case ",", "，": replacement = comma
            case "、": replacement = comma == "、" ? "、" : nil
            case ".": replacement = "。"
            default: replacement = fullWidthMarks[c]
            }
            if let replacement {
                out.append(replacement)
                skipSpaces = replacement != "（"
            } else {
                out.append(c)
                skipSpaces = isFullWidthMark(c) && c != "（"
            }
            i += 1
        }
        return out
    }

    private static func isInsideASCIIWord(_ prev: Character?, _ next: Character?) -> Bool {
        guard let prev, let next else { return false }
        return isASCIIWordCharacter(prev) && isASCIIWordCharacter(next)
    }

    private static func isASCIIWordCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    // MARK: - Half width

    private static let halfWidthMarks: [Character: String] = [
        "，": ",", "、": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";", "（": "(", "）": ")",
        "．": ".", "…": "...",
    ]

    private static func isFullWidthMark(_ c: Character) -> Bool {
        halfWidthMarks[c] != nil
    }

    private static func halfWidth(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard let replacement = halfWidthMarks[c] else {
                out.append(c)
                i += 1
                continue
            }
            if c == "…" {
                while i < chars.count, chars[i] == "…" { i += 1 }
            } else {
                i += 1
            }
            let next = i < chars.count ? chars[i] : nil
            if c == "（" {
                if let last = out.last, !last.isWhitespace { out.append(" ") }
                out.append(replacement)
            } else {
                out.append(replacement)
                if let next, !next.isWhitespace, !next.isPunctuation {
                    out.append(" ")
                }
            }
        }
        return out
    }

    // MARK: - Script tests

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        default: false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0xF900...0xFAFF: true
        default: false
        }
    }
}
