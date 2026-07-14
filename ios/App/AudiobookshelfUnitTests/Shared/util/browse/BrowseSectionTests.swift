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

    func testTrimsFairlyAcrossSections() {
        // 4 budget over [3, 2] → round-robin gives 2 and 2, not 3 and 1.
        let input = [section("A", ["1", "2", "3"]), section("B", ["4", "5"])]
        let out = BrowseSection.capped(input, maxItems: 4)
        XCTAssertEqual(out, [section("A", ["1", "2"]), section("B", ["4", "5"])])
    }

    func testLaterSectionNotStarvedByLongLeadingSection() {
        // Regression for the "Downloads always renders" invariant: a long leading section must not
        // consume the whole budget. 12 budget over [25, 10, 5] → ~4 each; the last section survives.
        let cont = section("Continue", (1...25).map(String.init))
        let recent = section("Recent", (26...35).map(String.init))
        let downloads = section("Downloads", (36...40).map(String.init))
        let out = BrowseSection.capped([cont, recent, downloads], maxItems: 12)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.header), ["Continue", "Recent", "Downloads"])
        XCTAssertFalse(out.last!.items.isEmpty, "Downloads must render even behind a long section")
        XCTAssertEqual(out.reduce(0) { $0 + $1.items.count }, 12)
    }

    func testDropsSectionsBeyondBudget() {
        // When the budget is smaller than the section count, trailing sections are dropped.
        let input = [section("A", ["1"]), section("B", ["2"]), section("C", ["3"])]
        let out = BrowseSection.capped(input, maxItems: 2)
        XCTAssertEqual(out.map(\.header), ["A", "B"])
    }

    func testZeroBudgetYieldsEmpty() {
        XCTAssertTrue(BrowseSection.capped([section("A", ["1"])], maxItems: 0).isEmpty)
    }

    func testEmptySectionsFilteredOut() {
        let input = [section("A", []), section("B", ["1"])]
        XCTAssertEqual(BrowseSection.capped(input, maxItems: 12), [section("B", ["1"])])
    }
}
