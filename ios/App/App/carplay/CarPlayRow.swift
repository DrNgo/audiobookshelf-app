//
//  CarPlayRow.swift
//  App
//
//  Shared builder for a CarPlay list row that carries an optional trailing "active" checkmark — the
//  code-controlled active-state indicator used by both the library picker and the chapter list, so
//  selection state does not depend on CarPlay's row-focus highlight (which cannot be moved via any
//  public API).
//

import CarPlay
import UIKit

enum CarPlayRow {
    /// A selectable list row with an optional trailing checkmark when `isActive`. `onSelect` runs
    /// after the row's completion block fires.
    ///
    /// Construct on the main thread — CPListItem is a main-thread-only CarPlay template object (the
    /// callers here already build rows on the main actor).
    ///
    /// - Note: `CPListItem.accessoryImage` is get-only, so the checkmark must be supplied at
    ///   construction — it cannot be toggled later.
    static func selectable(text: String, detailText: String? = nil, isActive: Bool,
                           onSelect: @escaping () -> Void) -> CPListItem {
        let checkmark = isActive ? UIImage(systemName: "checkmark") : nil
        let item = CPListItem(text: text, detailText: detailText, image: nil,
                              accessoryImage: checkmark, accessoryType: .none)
        item.handler = { _, completion in
            completion()
            onSelect()
        }
        return item
    }
}
