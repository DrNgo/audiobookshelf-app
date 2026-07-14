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
    /// Trim `sections` so their combined item count is at most `maxItems`, distributing the budget
    /// **fairly** across the non-empty sections (round-robin, one item per section per pass) rather
    /// than filling in order. Fairness matters because CarPlay's `maximumItemCount` can be as low as
    /// 12 while driving: an in-order fill would let a long leading section (e.g. 25 in-progress books)
    /// starve later ones — and the last section is "Downloads", which must always render because a car
    /// is frequently offline. Each section keeps its item order; sections keep their order; a section
    /// that receives zero items is dropped. `maxItems <= 0` yields no sections.
    static func capped(_ sections: [BrowseSection], maxItems: Int) -> [BrowseSection] {
        guard maxItems > 0 else { return [] }
        let present = sections.filter { !$0.items.isEmpty }
        guard !present.isEmpty else { return [] }

        var taken = [Int](repeating: 0, count: present.count)
        var remaining = maxItems
        var madeProgress = true
        while remaining > 0 && madeProgress {
            madeProgress = false
            for (i, section) in present.enumerated() where remaining > 0 {
                if taken[i] < section.items.count {
                    taken[i] += 1
                    remaining -= 1
                    madeProgress = true
                }
            }
        }

        return present.enumerated().compactMap { i, section in
            taken[i] > 0 ? BrowseSection(header: section.header, items: Array(section.items.prefix(taken[i]))) : nil
        }
    }
}
