//
//  CarPlayManager.swift
//  App
//
//  Builds and drives the CarPlay UI: a tab bar with Home (Continue Listening / Recently Added /
//  Downloads), Library (switch which server library feeds Recently Added), and Search. Server
//  sections are best-effort — offline they are omitted, leaving the always-available Downloads
//  section. All lists honor CPListTemplate.maximumItemCount.
//

import CarPlay
import UIKit

final class CarPlayManager {
    let interfaceController: CPInterfaceController
    private let tabBar = CPTabBarTemplate(templates: [])
    private let homeTemplate = CPListTemplate(title: "Home", sections: [])

    private var libraryController: CarPlayLibraryController?
    private var searchController: CarPlaySearchController?

    /// The library whose "Recently Added" shelf feeds Home. Defaults to the first book library.
    var activeLibraryId: String?

    /// The in-flight Home reload, cancelled when a newer reload starts so a slow older one can't win.
    private var homeTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        let library = CarPlayLibraryController(manager: self)
        let search = CarPlaySearchController(manager: self)
        self.libraryController = library
        self.searchController = search

        homeTemplate.tabTitle = "Home"
        homeTemplate.tabImage = UIImage(systemName: "house")
        tabBar.updateTemplates([homeTemplate, library.template, search.template])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        rebuildHome()
    }

    // MARK: - Home

    func rebuildHome() {
        homeTask?.cancel()
        homeTask = Task { [weak self] in
            guard let self = self else { return }
            if self.activeLibraryId == nil { self.activeLibraryId = await BrowseApi.firstBookLibraryId() }
            let continueListening = await BrowseApi.continueListening()
            var recentlyAdded: [BrowseItem] = []
            if let libraryId = self.activeLibraryId {
                recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId)
            }
            let downloads = BrowseApi.downloads()
            if Task.isCancelled { return }

            // capped() distributes the budget fairly and drops empty sections, so Downloads always
            // renders even behind a long Continue Listening section.
            let sections = BrowseSection.capped([
                BrowseSection(header: "Continue Listening", items: continueListening),
                BrowseSection(header: "Recently Added", items: recentlyAdded),
                BrowseSection(header: "Downloads", items: downloads),
            ], maxItems: CPListTemplate.maximumItemCount)

            // Build CarPlay template objects on the main thread (CPListItem/CPListSection are
            // main-thread-only), and bail if a newer reload superseded this one.
            await MainActor.run {
                if Task.isCancelled { return }
                let listSections = sections.map {
                    CPListSection(items: $0.items.map(self.makeRow), header: $0.header, sectionIndexTitle: nil)
                }
                let final = listSections.isEmpty
                    ? [CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)])]
                    : listSections
                self.homeTemplate.updateSections(final)
            }
        }
    }

    // MARK: - Row mapping (shared with search)

    func makeRow(_ item: BrowseItem) -> CPListItem {
        let row = CPListItem(text: item.title, detailText: item.author)
        row.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in
                BrowsePlaybackStarter.play(item) {
                    self?.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
            }
        }
        loadCover(item, into: row)
        return row
    }

    private func loadCover(_ item: BrowseItem, into row: CPListItem) {
        guard let url = item.coverURL else { return }
        ApiClient.getData(from: url) { [weak self] image in
            guard let image = image else { return }
            let sized = self?.sizedCover(image) ?? image
            DispatchQueue.main.async { row.setImage(sized) }
        }
    }

    /// Crop to a centered square and resize to CPListItem.maximumImageSize at the car's display
    /// scale, so covers render crisply without shipping oversized bitmaps to the head unit.
    private func sizedCover(_ image: UIImage) -> UIImage {
        let maxPoints = CPListItem.maximumImageSize
        guard maxPoints.width > 0, maxPoints.height > 0, let cg = image.cgImage else { return image }
        // Crop in the CGImage's PIXEL space (not UIImage points) so a non-1x source is handled correctly.
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(w, h)
        let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: cropRect) else { return image }
        let square = UIImage(cgImage: cropped)
        let format = UIGraphicsImageRendererFormat()
        format.scale = interfaceController.carTraitCollection.displayScale
        let renderer = UIGraphicsImageRenderer(size: maxPoints, format: format)
        return renderer.image { _ in square.draw(in: CGRect(origin: .zero, size: maxPoints)) }
    }
}
