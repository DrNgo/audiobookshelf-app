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
    ///
    /// `excludeNames` (authors + narrators) is a blacklist: those are real-person
    /// names, not spoken characters — and for dramatized / GraphicAudio titles the
    /// narrators list is the entire voice cast. Any term matching one (case-
    /// insensitively) is dropped, whether it came from the prose or the fields.
    static func build(fields: [String],
                      bookBlurb: String,
                      seriesBlurbs: [String],
                      excludeNames: [String] = [],
                      cap: Int = 100) -> [String] {
        // A single author/narrator field can pack several people into one string,
        // e.g. "Kumo Kagyu, Noboru Kannatuki - illustrator, Kevin Steinbach". Blacklist
        // the whole string AND each comma-separated name (minus any " - role" suffix)
        // so an individually-extracted name still matches.
        var blacklist = Set<String>()
        for name in excludeNames {
            let whole = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !whole.isEmpty { blacklist.insert(whole) }
            for piece in name.split(separator: ",") {
                var p = String(piece)
                if let dash = p.range(of: " - ") { p = String(p[..<dash.lowerBound]) }
                let key = p.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty { blacklist.insert(key) }
            }
        }

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
            if blacklist.contains(key) { continue }               // author/narrator names
            if seen.insert(key).inserted { result.append(trimmed) }
            if result.count >= cap { break }
        }
        return result
    }

    /// Names in `text`: NER (real names/places/orgs) unioned with Title-Case
    /// proper nouns (invented names NER misses). De-dup happens in `build`.
    /// HTML is stripped first (some blurbs are HTML), then the cast/credits tail
    /// is dropped — see `stripHTML` and `stripCreditsBlock`.
    private static func names(in text: String) -> [String] {
        let text = stripCreditsBlock(stripHTML(text))
        guard !text.isEmpty else { return [] }
        var found = nerNames(in: text)
        found.append(contentsOf: capitalizedPhrases(in: text))
        return found
    }

    /// Some servers store blurbs as HTML (`<p>…</p><br>`). Strip tags and decode
    /// the handful of entities that occur in practice so markup never fuses into
    /// a term (e.g. "Nova Terra.</p>"). Cheap no-op when the text is plain.
    private static func stripHTML(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") || text.contains("\u{00A0}") else { return text }
        var s = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "\u{00A0}": " ", "&amp;": "&", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        return s
    }

    /// Phrases that open a cast/production credits block. GraphicAudio and other
    /// dramatized/full-cast titles append a list of performers ("Performed by X
    /// as Y, ...") to the blurb; those are real-person names never spoken in the
    /// audio, and they flood the (capped) vocabulary — especially across a dozen
    /// series-sibling blurbs. Anything from the earliest marker onward is dropped.
    ///
    /// Markers are enumeration openers (they sit right before the name list), not
    /// generic branding: "GraphicAudio" is deliberately excluded because it can
    /// precede the synopsis ("GraphicAudio presents…"), where truncating would
    /// discard the very character names we want.
    private static let creditsMarkers: [String] = [
        "performed by", "narrated by", "featuring the voices", "featuring the voice",
        "directed by", "produced by", "adapted by", "dramatized by", "voices by",
        "a full cast", "a full-cast", "with a full cast", "cast includes", "cast:",
        // Non-synopsis boilerplate sections that follow the story text: series
        // marketing ("About the Series: …genre tags…") and store/format notes.
        "about the series", "please note"
    ]

    /// The blurb text up to (not including) the first credits marker, or the whole
    /// text when none is present. Case-insensitive.
    private static func stripCreditsBlock(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var cut: String.Index?
        for marker in creditsMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive),
               cut == nil || range.lowerBound < cut! {
                cut = range.lowerBound
            }
        }
        guard let cut else { return text }
        return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Function words stripped from the FRONT of a multi-word Title-Case phrase when
    /// sentence capitalization drags them in ("For John Sutton" → "John Sutton",
    /// "In The Psychology" → "Psychology"). Intentionally excludes adjectives/nouns
    /// like "new"/"old"/"book" so real names keep their first word ("New York",
    /// "New Dawn" survive).
    private static let leadingStripWords: Set<String> = [
        "the","a","an","and","or","but","if","of","to","in","on","at","by","for","with",
        "as","from","when","while","after","before","then","this","that","these","those",
        "despite","because","about","so","yet","just","into","also"
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
            while words.count > 1, leadingStripWords.contains(words[0].lowercased()) {
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
