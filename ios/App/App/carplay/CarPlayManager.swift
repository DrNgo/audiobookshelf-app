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
        Task {
            if activeLibraryId == nil { activeLibraryId = await BrowseApi.firstBookLibraryId() }
            let continueListening = await BrowseApi.continueListening()
            var recentlyAdded: [BrowseItem] = []
            if let libraryId = activeLibraryId {
                recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId)
            }
            let downloads = BrowseApi.downloads()

            var sections = [
                BrowseSection(header: "Continue Listening", items: continueListening),
                BrowseSection(header: "Recently Added", items: recentlyAdded),
                BrowseSection(header: "Downloads", items: downloads),
            ].filter { !$0.items.isEmpty }
            sections = BrowseSection.capped(sections, maxItems: CPListTemplate.maximumItemCount)

            let listSections = sections.map {
                CPListSection(items: $0.items.map(makeRow), header: $0.header, sectionIndexTitle: nil)
            }
            let final = listSections.isEmpty
                ? [CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)])]
                : listSections
            await MainActor.run { self.homeTemplate.updateSections(final) }
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

    /// Placeholder until list covers are sized to CPListItem.maximumImageSize.
    private func sizedCover(_ image: UIImage) -> UIImage { image }
}
