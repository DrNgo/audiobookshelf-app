//
//  CarPlayListItemTests.swift
//  AudiobookshelfUnitTests
//
//  Unit tests for the pure CarPlay browse mappers (server JSON -> view models). The local-item
//  mapper reads a Realm object and is exercised via the app at runtime, not here.
//

import XCTest
@testable import Audiobookshelf

final class CarPlayListItemTests: XCTestCase {
    private let server = "https://abs.example.com"

    func testItemsInProgressMapsRows() throws {
        let json = Data("""
        { "libraryItems": [
            { "id": "li_1", "media": { "coverPath": "/covers/1.webp", "metadata": { "title": "Book One", "authorName": "Author A" } } },
            { "id": "li_2", "media": { "metadata": { "title": "Book Two" } } }
        ] }
        """.utf8)

        let rows = CarPlayListItem.fromItemsInProgress(data: json, serverAddress: server)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], CarPlayListItem(
            id: "li_1", title: "Book One", author: "Author A", isLocal: false,
            coverURL: URL(string: "https://abs.example.com/api/items/li_1/cover?format=jpeg")))
        // No coverPath -> no cover URL; missing authorName -> nil.
        XCTAssertEqual(rows[1].title, "Book Two")
        XCTAssertNil(rows[1].author)
        XCTAssertNil(rows[1].coverURL)
    }

    func testItemsInProgressSkipsRowsWithoutId() {
        let json = Data("""
        { "libraryItems": [
            { "media": { "metadata": { "title": "No ID" } } },
            { "id": "", "media": { "metadata": { "title": "Empty ID" } } },
            { "id": "li_ok", "media": { "metadata": { "title": "OK" } } }
        ] }
        """.utf8)
        let rows = CarPlayListItem.fromItemsInProgress(data: json, serverAddress: server)
        XCTAssertEqual(rows.map(\.id), ["li_ok"])
    }

    func testPersonalizedPicksRecentlyAddedShelfOnly() {
        let json = Data("""
        [
          { "id": "continue-listening", "entities": [ { "id": "skip", "media": { "metadata": { "title": "Skip" } } } ] },
          { "id": "recently-added", "entities": [
              { "id": "li_r", "media": { "coverPath": "/c.webp", "metadata": { "title": "Recent", "authorName": "RA" } } }
          ] }
        ]
        """.utf8)
        let rows = CarPlayListItem.fromPersonalizedRecentlyAdded(data: json, serverAddress: server)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "li_r")
        XCTAssertEqual(rows[0].coverURL, URL(string: "https://abs.example.com/api/items/li_r/cover?format=jpeg"))
    }

    func testPersonalizedMissingShelfYieldsEmpty() {
        let json = Data("""
        [ { "id": "continue-listening", "entities": [ { "id": "x", "media": { "metadata": { "title": "X" } } } ] } ]
        """.utf8)
        XCTAssertTrue(CarPlayListItem.fromPersonalizedRecentlyAdded(data: json, serverAddress: server).isEmpty)
    }

    func testMalformedDataYieldsEmpty() {
        XCTAssertTrue(CarPlayListItem.fromItemsInProgress(data: Data("not json".utf8), serverAddress: server).isEmpty)
        XCTAssertTrue(CarPlayListItem.fromPersonalizedRecentlyAdded(data: Data("{}".utf8), serverAddress: server).isEmpty)
    }

    func testCoverURLGating() {
        XCTAssertNil(CarPlayListItem.coverURL(libraryItemId: "x", hasCover: false, serverAddress: server))
        XCTAssertNil(CarPlayListItem.coverURL(libraryItemId: "x", hasCover: true, serverAddress: nil))
        XCTAssertNil(CarPlayListItem.coverURL(libraryItemId: "x", hasCover: true, serverAddress: ""))
        XCTAssertEqual(
            CarPlayListItem.coverURL(libraryItemId: "x", hasCover: true, serverAddress: server),
            URL(string: "https://abs.example.com/api/items/x/cover?format=jpeg"))
    }
}
