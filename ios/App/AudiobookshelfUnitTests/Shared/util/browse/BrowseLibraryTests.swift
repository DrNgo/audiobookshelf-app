import XCTest
@testable import Audiobookshelf

final class BrowseLibraryTests: XCTestCase {
    func testKeepsBookLibrariesOnly() {
        let json = Data("""
        { "libraries": [
            { "id": "lib_b", "name": "Books", "mediaType": "book" },
            { "id": "lib_p", "name": "Podcasts", "mediaType": "podcast" },
            { "id": "lib_b2", "name": "Sci-Fi", "mediaType": "book" }
        ] }
        """.utf8)
        XCTAssertEqual(BrowseLibrary.fromLibraries(data: json),
                       [BrowseLibrary(id: "lib_b", name: "Books"),
                        BrowseLibrary(id: "lib_b2", name: "Sci-Fi")])
    }

    func testDropsEntriesMissingIdOrName() {
        let json = Data("""
        { "libraries": [
            { "name": "No ID", "mediaType": "book" },
            { "id": "lib_ok", "name": "OK", "mediaType": "book" },
            { "id": "lib_noname", "mediaType": "book" }
        ] }
        """.utf8)
        XCTAssertEqual(BrowseLibrary.fromLibraries(data: json).map(\.id), ["lib_ok"])
    }

    func testMalformedYieldsEmpty() {
        XCTAssertTrue(BrowseLibrary.fromLibraries(data: Data("nope".utf8)).isEmpty)
    }
}
