import Foundation

/// Removes the stock phrases Whisper produces when it hears silence or noise instead of speech.
///
/// These are closing lines from the subtitles Whisper was trained on. They are far more likely to
/// be a hallucination than something the speaker actually said, so they are stripped regardless of
/// the selected language.
enum HallucinationFilter {
    static let phrases: [String] = [
        // Japanese
        "ご視聴ありがとうございました", "ご視聴ありがとうございます", "ご視聴いただきありがとうございます",
        "最後までご視聴いただきありがとうございました", "チャンネル登録お願いします", "チャンネル登録よろしくお願いします",
        "チャンネル登録をお願いします", "次回もお楽しみに",
        // Chinese
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目", "明鏡與點點欄目", "明镜与点点栏目", "字幕由Amara.org社区提供",
        "字幕由 Amara.org 社区提供", "謝謝觀看", "谢谢观看", "感謝觀看", "感谢观看", "謝謝大家收看", "谢谢大家收看",
        "請訂閱", "请订阅", "字幕志愿者", "字幕志願者",
        // Korean
        "시청해주셔서 감사합니다", "시청해 주셔서 감사합니다", "구독과 좋아요",
        // English
        "Thank you for watching", "Thanks for watching", "Thank you so much for watching",
        "Subtitles by the Amara.org community", "Subtitles by", "Please subscribe", "Like and subscribe",
        "Don't forget to subscribe",
    ]

    /// Returns `text` with known hallucinated phrases removed, or an empty string when nothing else remains.
    static func strip(_ text: String) -> String {
        var result = text
        for phrase in phrases {
            result = result.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return isOnlyPunctuation(result) ? "" : result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isOnlyPunctuation(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }
    }
}
