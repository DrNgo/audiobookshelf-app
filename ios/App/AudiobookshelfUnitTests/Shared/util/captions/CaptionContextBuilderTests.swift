//
//  CaptionContextBuilderTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionContextBuilderTests: XCTestCase {

    // NER pulls person/place names out of a blurb.
    //
    // Surface-form note: NLTagger on this OS build (iOS 26.5 simulator, confirmed matching
    // on macOS) does not reliably classify invented fantasy place names (e.g. "Luthadel")
    // as `.placeName` — it either drops them or mis-tags them as `.personalName` depending
    // on sentence context. Real-world place names (Paris, London, ...) are recognized
    // reliably. The brief authorizes adjusting surface forms to the tagger's actual
    // behavior, so this blurb uses a real place name to exercise the `.placeName` path
    // genuinely, while keeping the fictional person names (which the tagger does resolve
    // reliably) from the original brief.
    func testExtractsPersonAndPlaceNamesFromBlurb() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Vin grew up in Paris. Kelsier was a rebel leader.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Vin"), "expected person name Vin; got \(terms)")
        XCTAssertTrue(terms.contains("Kelsier"), "expected person name Kelsier; got \(terms)")
        XCTAssertTrue(terms.contains("Paris"), "expected place name Paris; got \(terms)")
    }

    // Structured fields are always included.
    func testIncludesStructuredFields() {
        let terms = CaptionContextBuilder.build(
            fields: ["Brandon Sanderson", "Michael Kramer"],
            bookBlurb: "",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Brandon Sanderson"))
        XCTAssertTrue(terms.contains("Michael Kramer"))
    }

    // Case-insensitive dedupe, first surface form preserved.
    func testDedupesCaseInsensitively() {
        let terms = CaptionContextBuilder.build(
            fields: ["Vin"],
            bookBlurb: "Vin walked. vin ran.",
            seriesBlurbs: []
        )
        XCTAssertEqual(terms.filter { $0.lowercased() == "vin" }.count, 1)
    }

    // Priority: current-book names precede series-sibling names precede fields.
    func testPriorityOrdering() {
        let terms = CaptionContextBuilder.build(
            fields: ["Tor Books"],
            bookBlurb: "Kelsier led the crew.",
            seriesBlurbs: ["The Lord Ruler reigns over the Final Empire."]
        )
        let kelsier = terms.firstIndex(of: "Kelsier")
        let lordRuler = terms.firstIndex { $0.contains("Lord Ruler") }
        let tor = terms.firstIndex(of: "Tor Books")
        XCTAssertNotNil(kelsier); XCTAssertNotNil(tor)
        if let k = kelsier, let t = tor { XCTAssertLessThan(k, t, "current-book name before field") }
        if let l = lordRuler, let t = tor { XCTAssertLessThan(l, t, "sibling name before field") }
    }

    // Cap keeps the highest-priority terms.
    //
    // Surface-form note: "Kelsier stood." (2 words) is too short a context window for
    // NLTagger to classify "Kelsier" as a name on this OS build (confirmed via direct
    // probe); "Kelsier led the crew." resolves reliably, matching testPriorityOrdering
    // below which already uses that exact sentence successfully.
    func testCapIsEnforcedKeepingHighestPriority() {
        let manyFields = (0..<200).map { "Field\($0)" }
        let terms = CaptionContextBuilder.build(
            fields: manyFields,
            bookBlurb: "Kelsier led the crew.",
            seriesBlurbs: [],
            cap: 10
        )
        XCTAssertLessThanOrEqual(terms.count, 10)
        XCTAssertEqual(terms.first, "Kelsier", "current-book name survives the cap first")
    }

    // Empty corpus → fields only, no crash.
    func testEmptyCorpusReturnsFieldsOnly() {
        let terms = CaptionContextBuilder.build(fields: ["Author Name"], bookBlurb: "", seriesBlurbs: [])
        XCTAssertEqual(terms, ["Author Name"])
    }

    func testEverythingEmptyReturnsEmpty() {
        XCTAssertEqual(CaptionContextBuilder.build(fields: [], bookBlurb: "", seriesBlurbs: []), [])
    }

    // The Title-Case heuristic catches invented names NER skips.
    func testHeuristicCatchesInventedNames() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "In the city of Luthadel, Vin joined a crew led by Kelsier.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Luthadel"), "expected invented place Luthadel; got \(terms)")
        XCTAssertTrue(terms.contains("Kelsier"), "expected invented name Kelsier; got \(terms)")
    }

    // Sentence-initial single common words are not treated as names.
    func testHeuristicDropsSentenceInitialCommonWords() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "The wind blew. In darkness they waited.",
            seriesBlurbs: []
        )
        XCTAssertFalse(terms.contains("The"), "got \(terms)")
        XCTAssertFalse(terms.contains("In"), "got \(terms)")
    }

    // A leading article is stripped from a multi-word Title-Case phrase.
    func testHeuristicStripsLeadingArticle() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "They feared The Final Empire.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Final Empire"), "got \(terms)")
        XCTAssertFalse(terms.contains("The Final Empire"), "got \(terms)")
    }

    // Possessive suffix stripped; a smart-quoted invented name still extracted cleanly.
    func testHeuristicHandlesPossessivesAndSmartQuotes() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Kelsier's crew marched. \u{201C}Luthadel\u{201D} burned.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Kelsier"), terms.description)
        XCTAssertFalse(terms.contains("Kelsier's"), terms.description)
        XCTAssertTrue(terms.contains("Luthadel"), terms.description)
        XCTAssertFalse(terms.contains { $0.contains("\u{201C}") || $0.contains("\u{201D}") },
                       "no smart quotes should survive in terms: \(terms.description)")
    }

    // Names separated by a sentence boundary wrapped in a closing quote must not fuse.
    func testHeuristicBreaksNamesAcrossQuotedSentenceBoundary() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "\u{201C}Luthadel.\u{201D} Kelsier returned to the crew.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Luthadel"), terms.description)
        XCTAssertTrue(terms.contains("Kelsier"), terms.description)
        XCTAssertFalse(terms.contains { $0.contains(" ") && $0.contains("Luthadel") },
                       "Luthadel must not fuse with the next name: \(terms.description)")
    }

    // Sentence-initial ordinary English words are dropped; invented names survive.
    func testHeuristicDropsSentenceInitialDictionaryWords() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Even the mighty fall. Harvest came early. Kithani watched from Aodar.",
            seriesBlurbs: []
        )
        XCTAssertFalse(terms.contains("Even"), terms.description)
        XCTAssertFalse(terms.contains("Harvest"), terms.description)
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertTrue(terms.contains("Aodar"), terms.description)
    }

    // Em-dash between words splits them instead of fusing (Riven—his → Riven).
    func testHeuristicSplitsOnEmDash() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "The warrior Vess\u{2014}his blade drawn\u{2014}advanced on Kithani.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Vess"), terms.description)
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertFalse(terms.contains { $0.contains("\u{2014}") }, "no em-dash in terms: \(terms.description)")
    }

    // GraphicAudio / dramatized blurbs append a "Performed by <performer> as <role>"
    // cast list. Those performer names are never spoken in the audio and must be
    // dropped, while the synopsis before the credits marker is still mined.
    func testStripsPerformedByCreditsBlock() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Kithani watched from Aodar as the empire fell. "
                + "Performed by Bradley Foster Smith as the King, "
                + "Nanette Savard as the Queen, Terence Aselford as the Herald.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Kithani"), "synopsis name kept; got \(terms)")
        XCTAssertTrue(terms.contains("Aodar"), "synopsis name kept; got \(terms)")
        XCTAssertFalse(terms.contains { $0.contains("Bradley") }, "performer dropped; got \(terms)")
        XCTAssertFalse(terms.contains { $0.contains("Savard") }, "performer dropped; got \(terms)")
        XCTAssertFalse(terms.contains { $0.contains("Aselford") }, "performer dropped; got \(terms)")
    }

    // "Narrated by <name>" credit tails are truncated too (case-insensitive).
    func testStripsNarratedByCreditsCaseInsensitively() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Kithani watched from Aodar. NARRATED BY James Konicek.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertFalse(terms.contains { $0.contains("Konicek") }, "narrator dropped; got \(terms)")
    }

    // The same truncation applies to series-sibling blurbs, which for dramatized
    // series are the biggest source of performer-name flooding.
    func testStripsCreditsInSeriesBlurbs() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "",
            seriesBlurbs: ["Kithani returned to Aodar. Performed by Danny Gavigan as the Warden."]
        )
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertFalse(terms.contains { $0.contains("Gavigan") }, "sibling performer dropped; got \(terms)")
    }

    // A blurb with no credits marker is mined in full — an ordinary "by" phrase
    // ("guided by", "written by" is not in the marker set) must not truncate it.
    func testBlurbWithoutCreditsMarkerUnaffected() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "Kithani was guided by Aodar through the ruins of Vess.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertTrue(terms.contains("Aodar"), terms.description)
        XCTAssertTrue(terms.contains("Vess"), terms.description)
    }

    // Author / narrator names are a blacklist: for dramatized titles the narrators
    // list is the entire voice cast. They must never appear as terms, whether they
    // came from the blurb prose or would have been added as fields.
    func testExcludeNamesAreRemovedFromVocabulary() {
        let terms = CaptionContextBuilder.build(
            fields: ["Battle Mage Farmer"],   // series name stays
            bookBlurb: "Kithani fought in Aodar. Rob McFadyen narrates the tale.",
            seriesBlurbs: [],
            excludeNames: ["Rob McFadyen", "Seth Ring"]
        )
        XCTAssertTrue(terms.contains("Kithani"), "character kept; got \(terms)")
        XCTAssertTrue(terms.contains("Battle Mage Farmer"), "series field kept; got \(terms)")
        XCTAssertFalse(terms.contains { $0.contains("McFadyen") }, "narrator dropped; got \(terms)")
        XCTAssertFalse(terms.contains("Seth Ring"), "author dropped; got \(terms)")
    }

    // The exclude match is case-insensitive and whitespace-trimmed.
    func testExcludeNamesMatchCaseInsensitively() {
        let terms = CaptionContextBuilder.build(
            fields: ["  JAMES LEWIS  "],
            bookBlurb: "",
            seriesBlurbs: [],
            excludeNames: ["James Lewis"]
        )
        XCTAssertFalse(terms.contains { $0.lowercased().contains("james lewis") }, "got \(terms)")
    }

    // HTML tags and entities in a blurb are stripped before extraction, so tokens
    // aren't corrupted (e.g. "Nova Terra.</p>" must not survive as a term).
    func testStripsHtmlTagsBeforeExtraction() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "<p>Kithani journeyed to Aodar.</p> <p>Author of Nova Terra.</p>",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Kithani"), terms.description)
        XCTAssertTrue(terms.contains("Aodar"), terms.description)
        XCTAssertTrue(terms.contains("Nova Terra"), "clean phrase kept; got \(terms)")
        XCTAssertFalse(terms.contains { $0.contains("<") || $0.contains(">") },
                       "no markup should survive in terms: \(terms.description)")
    }
}
