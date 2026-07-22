//
//  CaptionStoreTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captions-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func seg(_ start: Double, _ end: Double, _ text: String) -> CaptionSegment {
        CaptionSegment(start: start, end: end, text: text,
                       words: [CaptionWord(start: start, end: end, text: text)])
    }

    func testLoadOnMissingFileReturnsEmpty() {
        let store = CaptionStore(directory: dir)
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testAppendThenLoadRoundTrips() throws {
        let store = CaptionStore(directory: dir)
        let segs = [seg(0, 1, "hello"), seg(1, 2, "world")]
        try store.append(segs, locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US"), segs)
    }

    func testAppendAccumulatesAndSortsByStart() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(10, 11, "b")], locale: "en-US")
        try store.append([seg(0, 1, "a")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US").map(\.text), ["a", "b"])
    }

    // Re-transcribing the same region must not duplicate it.
    func testAppendDeduplicatesIdenticalStarts() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(5, 6, "once")], locale: "en-US")
        try store.append([seg(5, 6, "once")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US").count, 1)
    }

    // A device language change must not silently serve mismatched text.
    func testLoadWithDifferentLocaleReturnsEmpty() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "de-DE"), [])
    }

    func testAppendAfterLocaleChangeReplacesCache() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        try store.append([seg(0, 1, "hallo")], locale: "de-DE")
        XCTAssertEqual(store.load(locale: "de-DE").map(\.text), ["hallo"])
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testCorruptFileReturnsEmptyInsteadOfThrowing() throws {
        let store = CaptionStore(directory: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("captions.json"))
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testEvictRemovesTheFile() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        store.evict()
        XCTAssertEqual(store.load(locale: "en-US"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("captions.json").path))
    }
}
