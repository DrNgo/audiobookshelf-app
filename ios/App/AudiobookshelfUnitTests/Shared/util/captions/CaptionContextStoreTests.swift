//
//  CaptionContextStoreTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionContextStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLoadOnMissingFileReturnsEmpty() {
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["Vin", "Kelsier", "Luthadel"])
        XCTAssertEqual(store.load(), ["Vin", "Kelsier", "Luthadel"])
    }

    func testSaveOverwrites() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["A"])
        try store.save(["B", "C"])
        XCTAssertEqual(store.load(), ["B", "C"])
    }

    func testCorruptFileReturnsEmpty() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("context.json"))
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testWrongSchemaVersionReturnsEmpty() throws {
        let json = #"{"version": 999, "terms": ["X"]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("context.json"))
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testEvictRemovesFile() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["A"])
        store.evict()
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("context.json").path))
    }
}
