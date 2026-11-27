import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The system's spelling dictionary, on the device. Used to decide between two
/// hearings of the same word: "Aufsatz" is a word, "Aufstatt" is not.
@MainActor
enum WordCheck {
    #if canImport(UIKit)
    private static let checker = UITextChecker()
    private static var codes: [Language: String] = [:]

    private static func code(_ language: Language) -> String? {
        if let known = codes[language] { return known }
        let prefix = language.rawValue
        let found = UITextChecker.availableLanguages.first { $0 == (prefix == "de" ? "de_CH" : "en_US") }
            ?? UITextChecker.availableLanguages.first { $0.hasPrefix(prefix) }
        codes[language] = found
        return found
    }
    #endif

    /// Whether a dictionary for the language exists here at all.
    static func isAvailable(_ language: Language) -> Bool {
        #if canImport(UIKit)
        code(language) != nil
        #elseif canImport(AppKit)
        NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix(language.rawValue) }
        #else
        false
        #endif
    }

    static func isWord(_ word: String, in language: Language) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        #if canImport(UIKit)
        guard let code = code(language) else { return true }
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: code).location == NSNotFound
        #elseif canImport(AppKit)
        return NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language.rawValue, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
        #else
        return true
        #endif
    }
}
