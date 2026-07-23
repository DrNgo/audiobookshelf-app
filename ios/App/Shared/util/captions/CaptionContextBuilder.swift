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

    /// Person / place / organization names in `text`, in order of appearance.
    private static func names(in text: String) -> [String] {
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
}
