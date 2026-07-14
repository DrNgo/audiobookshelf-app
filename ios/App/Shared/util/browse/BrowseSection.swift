//
//  BrowseSection.swift
//  App
//
//  A titled group of BrowseItems plus the pure capping used to honor CarPlay's runtime
//  CPListTemplate.maximumItemCount (as low as 12 while driving). Kept free of the CarPlay
//  framework so it is unit-testable.
//

import Foundation

struct BrowseSection: Equatable {
    let header: String
    let items: [BrowseItem]
}

extension BrowseSection {
    /// Trim `sections` so their combined item count is at most `maxItems`, filling sections in
    /// order and dropping any section left empty. `maxItems <= 0` yields no sections.
    static func capped(_ sections: [BrowseSection], maxItems: Int) -> [BrowseSection] {
        guard maxItems > 0 else { return [] }
        var remaining = maxItems
        var result: [BrowseSection] = []
        for section in sections {
            guard remaining > 0 else { break }
            let take = Array(section.items.prefix(remaining))
            guard !take.isEmpty else { continue }
            result.append(BrowseSection(header: section.header, items: take))
            remaining -= take.count
        }
        return result
    }
}
