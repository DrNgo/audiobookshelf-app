import XCTest
@testable import Audiobookshelf

final class BrowseSectionTests: XCTestCase {
    private func item(_ id: String) -> BrowseItem {
        BrowseItem(id: id, title: id, author: nil, isLocal: false, coverURL: nil)
    }
    private func section(_ header: String, _ ids: [String]) -> BrowseSection {
        BrowseSection(header: header, items: ids.map(item))
    }

    func testUnderBudgetUnchanged() {
        let input = [section("A", ["1", "2"]), section("B", ["3"])]
        XCTAssertEqual(BrowseSection.capped(input, maxItems: 12), input)
    }

    func testTrimsAcrossSectionsInOrder() {
        let input = [section("A", ["1", "2", "3"]), section("B", ["4", "5"])]
        let out = BrowseSection.capped(input, maxItems: 4)
        XCTAssertEqual(out, [section("A", ["1", "2", "3"]), section("B", ["4"])])
    }

    func testDropsSectionThatBecomesEmpty() {
        let input = [section("A", ["1", "2", "3"]), section("B", ["4", "5"])]
        let out = BrowseSection.capped(input, maxItems: 3)
        XCTAssertEqual(out, [section("A", ["1", "2", "3"])])
    }

    func testZeroBudgetYieldsEmpty() {
        XCTAssertTrue(BrowseSection.capped([section("A", ["1"])], maxItems: 0).isEmpty)
    }
}
