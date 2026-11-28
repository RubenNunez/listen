import Foundation
import NaturalLanguage

/// Output language is independent of the topic's recognition language. Short ambiguous
/// fragments keep the topic language; confident whole utterances may use a supported tag.
enum LocalSpeechLanguage {
    static func code(for text: String, fallback: Language, supported: Set<String>) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8, supported.contains(language.rawValue) else { return fallback.rawValue }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let letters = text.filter(\.isLetter).count
        guard letters >= 12, words >= 4 || ["ja", "ko"].contains(language.rawValue) else { return fallback.rawValue }
        return language.rawValue
    }
}
