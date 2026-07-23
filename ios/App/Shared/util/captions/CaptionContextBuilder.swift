//
//  CaptionContextBuilder.swift
//  Audiobookshelf
//
//  Turns a book's (and its series siblings') metadata into a biasing vocabulary
//  for the speech recognizer. On-device NER (NLTagger) pulls the proper nouns ASR
//  mangles — character and place names — out of the blurbs; structured fields
//  (author/narrator/series/title) are merged in. Deduped, priority-ordered, capped.
//
//  No Speech / iOS-26 symbols here — this is version-agnostic and unit-tested.
//

import Foundation
import NaturalLanguage
import UIKit

enum CaptionContextBuilder {

    /// Build the ordered, deduped, capped biasing term list.
    /// Order: current-book names → series-sibling names → structured fields.
    static func build(fields: [String],
                      bookBlurb: String,
                      seriesBlurbs: [String],
                      cap: Int = 100) -> [String] {
        var ordered: [String] = []
        ordered.append(contentsOf: names(in: bookBlurb))          // current-book names first
        for blurb in seriesBlurbs { ordered.append(contentsOf: names(in: blurb)) }
        ordered.append(contentsOf: fields)                        // structured fields last

        // Case-insensitive dedupe preserving first-seen surface form.
        var seen = Set<String>()
        var result: [String] = []
        for term in ordered {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { result.append(trimmed) }
            if result.count >= cap { break }
        }
        return result
    }

    /// Names in `text`: NER (real names/places/orgs) unioned with Title-Case
    /// proper nouns (invented names NER misses). De-dup happens in `build`.
    private static func names(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var found = nerNames(in: text)
        found.append(contentsOf: capitalizedPhrases(in: text))
        return found
    }

    /// Person / place / organization names in `text`, in order of appearance.
    private static func nerNames(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        var found: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: options) { tag, range in
            if let tag = tag, wanted.contains(tag) {
                found.append(String(text[range]))
            }
            return true
        }
        return found
    }

    /// Single Title-Case words that are almost always sentence capitalization or
    /// function words rather than names — dropped when a phrase is just one of them.
    private static let commonWords: Set<String> = [
        "the","a","an","and","or","but","if","of","to","in","on","at","by","for","with",
        "he","she","it","they","we","i","you","his","her","their","our","its",
        "this","that","these","those","then","when","while","after","before","as","from",
        "one","two","three","first","new","old","now","here","there",
        "chapter","book","novel","story","series","tale","saga","volume","part"
    ]

    /// Title-Case proper-noun phrases in `text` — catches the invented names NER
    /// misses. Consecutive capitalized tokens form a phrase; a leading article is
    /// stripped; a single-word phrase is dropped if it is a common/function word,
    /// OR if it sits at a sentence start AND is a real English word (sentence
    /// capitalization of an ordinary word, not a name — invented names aren't in
    /// the dictionary, so they survive).
    private static func capitalizedPhrases(in text: String) -> [String] {
        var phrases: [String] = []
        var current: [String] = []
        var runStartsSentence = false
        var atSentenceStart = true
        let checker = UITextChecker()
        let punctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}—–-…\u{201C}\u{201D}\u{2018}\u{2019}«»")
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "»"]

        func isDictionaryWord(_ word: String) -> Bool {
            let w = word.lowercased()
            let ns = w as NSString
            guard ns.length > 0 else { return false }
            let r = checker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: ns.length),
                                                  startingAt: 0, wrap: false, language: "en")
            return r.location == NSNotFound
        }

        func flush() {
            guard !current.isEmpty else { return }
            var words = current
            let startedSentence = runStartsSentence
            current = []
            runStartsSentence = false
            if words.count > 1, ["the", "a", "an"].contains(words[0].lowercased()) {
                words.removeFirst()
            }
            guard !words.isEmpty else { return }
            if words.count == 1 {
                let w = words[0]
                if commonWords.contains(w.lowercased()) { return }
                if startedSentence, isDictionaryWord(w) { return }
            }
            let phrase = words.joined(separator: " ")
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }

        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{2014}" || $0 == "\u{2013}" }) {
            var token = String(raw).trimmingCharacters(in: punctuation)
            for possessive in ["'s", "\u{2019}s", "'", "\u{2019}"] {
                if token.hasSuffix(possessive) { token = String(token.dropLast(possessive.count)); break }
            }
            let firstScalar = token.unicodeScalars.first
            let isCapitalized = token.count > 1 && firstScalar.map { CharacterSet.uppercaseLetters.contains($0) } == true
            if isCapitalized {
                if current.isEmpty { runStartsSentence = atSentenceStart }
                current.append(token)
            } else {
                flush()
            }
            var boundary = raw
            while let last = boundary.last, closers.contains(last) { boundary = boundary.dropLast() }
            if let last = boundary.last, ".!?".contains(last) {
                flush()
                atSentenceStart = true
            } else if let last = boundary.last, ",;:".contains(last) {
                flush()
                atSentenceStart = false
            } else {
                atSentenceStart = false
            }
        }
        flush()
        return phrases
    }
}
