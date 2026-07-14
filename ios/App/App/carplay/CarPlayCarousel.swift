//
//  CarPlayCarousel.swift
//  App
//
//  Builds a Home shelf as a single horizontal cover carousel (CPListImageRowItem) with a per-cover
//  title. Per-cover titles are only available on newer iOS, so the ENTIRE iOS version ladder lives
//  here in one place — the element-construction APIs and the matching cover size that must agree with
//  them: iOS 26 uses `elements`, iOS 17.4-25 uses `imageTitles`, older iOS shows covers without
//  captions. Missing covers use a placeholder so the row can render before covers finish loading.
//

import CarPlay
import UIKit

// @MainActor: every method constructs/mutates main-thread-only CarPlay template objects.
@MainActor
enum CarPlayCarousel {
    /// A neutral placeholder shown until a real cover loads (or when a cover fails to load).
    static let placeholder: UIImage = UIImage(systemName: "book.closed") ?? UIImage()

    /// The target size for a carousel cover — the image-row element max (NOT the list-item max),
    /// laddered the same way as the element construction below so sizing and layout always agree.
    static var maximumImageSize: CGSize {
        if #available(iOS 26.0, *) { return CPListImageRowItemRowElement.maximumImageSize }
        return CPListImageRowItem.maximumImageSize
    }

    /// Build a shelf carousel showing placeholder covers; real covers are swapped in later via
    /// `applyCovers`. `items` must already be capped to `CPMaximumNumberOfGridImages` by the caller,
    /// which also drives cover loading over the same list, so the two must line up.
    static func make(title: String, items: [BrowseItem],
                     onSelect: @escaping (Int) -> Void) -> CPListImageRowItem {
        let titles = items.map { $0.title }
        let row = buildRow(text: title, images: Array(repeating: placeholder, count: items.count), titles: titles)
        row.listImageRowHandler = { _, index, completion in
            completion()
            onSelect(index)
        }
        // Tapping a cover fires listImageRowHandler; tapping the cell/title area fires `handler`.
        // Without a handler, CarPlay treats the title tap as a pending selection and shows a spinner
        // that never resolves. The shelf title isn't a navigation target, so make it a no-op that
        // immediately completes.
        row.handler = { _, completion in completion() }
        return row
    }

    /// Reload a carousel's images in place once covers have loaded, keeping the per-cover titles.
    static func applyCovers(_ covers: [UIImage?], to row: CPListImageRowItem, titles: [String]) {
        let images = titles.indices.map { covers.indices.contains($0) ? (covers[$0] ?? placeholder) : placeholder }
        if #available(iOS 26.0, *) {
            row.elements = rowElements(images, titles)
        } else {
            // `updateImages(_:)` was renamed to `update(_:)` in the Xcode 26 SDK; only reached on < iOS 26.
            row.update(images)
        }
    }

    // MARK: - Version ladder (kept in one place)

    private static func buildRow(text: String, images: [UIImage], titles: [String]) -> CPListImageRowItem {
        if #available(iOS 26.0, *) {
            return CPListImageRowItem(text: text, elements: rowElements(images, titles), allowsMultipleLines: false)
        } else if #available(iOS 17.4, *) {
            return CPListImageRowItem(text: text, images: images, imageTitles: titles)
        } else {
            return CPListImageRowItem(text: text, images: images)
        }
    }

    @available(iOS 26.0, *)
    private static func rowElements(_ images: [UIImage], _ titles: [String]) -> [CPListImageRowItemRowElement] {
        zip(images, titles).map { CPListImageRowItemRowElement(image: $0, title: $1, subtitle: nil) }
    }
}
