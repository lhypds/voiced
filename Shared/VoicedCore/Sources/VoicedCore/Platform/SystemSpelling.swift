import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The hint policy is shared; only the system dictionary API differs between platforms.
enum SystemSpelling {
    @MainActor
    static func misspelledRange(in text: String, startingAt start: Int, language code: String) -> NSRange {
        #if os(macOS)
        return NSSpellChecker.shared.checkSpelling(of: text, startingAt: start, language: code,
                                                  wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        #elseif os(iOS)
        let language = UITextChecker.availableLanguages.first {
            $0 == code || $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-")
        } ?? code
        return UITextChecker().rangeOfMisspelledWord(in: text, range: NSRange(location: start, length: (text as NSString).length - start),
                                                    startingAt: start, wrap: false, language: language)
        #endif
    }
}
