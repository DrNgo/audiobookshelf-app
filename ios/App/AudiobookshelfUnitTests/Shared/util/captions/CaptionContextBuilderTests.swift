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
}
