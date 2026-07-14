//
//  CarPlayCarousel.swift
//  App
//
//  Builds a Home shelf as a single horizontal cover carousel (CPListImageRowItem) with a per-cover
//  title. Per-cover titles are only available on newer iOS, so the version ladder lives here in one
//  place: iOS 26 uses `elements`, iOS 17.4-25 uses `imageTitles`, older iOS shows covers without
//  captions. Missing covers use a placeholder so the row can render before covers finish loading.
//

import CarPlay
import UIKit

// @MainActor: every method constructs/mutates main-thread-only CarPlay template objects.
@MainActor
enum CarPlayCarousel {
    /// A neutral placeholder shown until a real cover loads (or when a cover fails to load).
    static let placeholder: UIImage = UIImage(systemName: "book.closed") ?? UIImage()

    static func make(title: String, items: [BrowseItem], covers: [UIImage?],
                     onSelect: @escaping (Int) -> Void) -> CPListImageRowItem {
        let capped = Array(items.prefix(Int(CPMaximumNumberOfGridImages)))
        let titles = capped.map { $0.title }
        let images = (0..<capped.count).map { covers.indices.contains($0) ? (covers[$0] ?? placeholder) : placeholder }

        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            let elements = zip(images, titles).map { CPListImageRowItemRowElement(image: $0, title: $1, subtitle: nil) }
            row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
        } else if #available(iOS 17.4, *) {
            row = CPListImageRowItem(text: title, images: images, imageTitles: titles)
        } else {
            row = CPListImageRowItem(text: title, images: images)
        }
        row.listImageRowHandler = { _, index, completion in
            completion()
            onSelect(index)
        }
        return row
    }

    /// Reload a carousel's images in place once covers have loaded, keeping the per-cover titles.
    static func applyCovers(_ covers: [UIImage?], to row: CPListImageRowItem, titles: [String]) {
        let images = (0..<titles.count).map { covers.indices.contains($0) ? (covers[$0] ?? placeholder) : placeholder }
        if #available(iOS 26.0, *) {
            row.elements = zip(images, titles).map { CPListImageRowItemRowElement(image: $0, title: $1, subtitle: nil) }
        } else {
            // `updateImages(_:)` was renamed to `update(_:)` in the Xcode 26 SDK; only reached on < iOS 26.
            row.update(images)
        }
    }
}
