//
//  CarPlayManager.swift
//  App
//
//  Builds and drives the CarPlay browse UI: a root list with "Continue Listening" and
//  "Recently Added" (server) and "Downloads" (local) sections. Selecting a row starts playback
//  and presents the system Now Playing screen. Server sections are best-effort — on offline or
//  error they are simply omitted, leaving the always-available Downloads section, because a car
//  is frequently offline.
//

import CarPlay
import UIKit

final class CarPlayManager {
    private let interfaceController: CPInterfaceController
    private let rootTemplate: CPListTemplate

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.rootTemplate = CPListTemplate(title: "Audiobookshelf", sections: [])
    }

    func start() {
        interfaceController.setRootTemplate(rootTemplate, animated: false, completion: nil)
        Task { await reload() }
    }

    // MARK: - Loading

    private func reload() async {
        // Downloads are local and synchronous; the server sources load over the network.
        let downloads = BrowseApi.downloads()
        let continueListening = await BrowseApi.continueListening()
        var recentlyAdded: [BrowseItem] = []
        if let libraryId = await BrowseApi.firstBookLibraryId() {
            recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId)
        }

        let sections = buildSections(continueListening: continueListening,
                                     recentlyAdded: recentlyAdded,
                                     downloads: downloads)
        await MainActor.run { self.rootTemplate.updateSections(sections) }
    }

    private func buildSections(continueListening: [BrowseItem],
                               recentlyAdded: [BrowseItem],
                               downloads: [BrowseItem]) -> [CPListSection] {
        var sections: [CPListSection] = []
        func addSection(_ title: String, _ items: [BrowseItem]) {
            guard !items.isEmpty else { return }
            sections.append(CPListSection(items: items.map(makeRow), header: title, sectionIndexTitle: nil))
        }
        addSection("Continue Listening", continueListening)
        addSection("Recently Added", recentlyAdded)
        addSection("Downloads", downloads)

        if sections.isEmpty {
            sections.append(CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)]))
        }
        return sections
    }

    // MARK: - Rows

    private func makeRow(_ item: BrowseItem) -> CPListItem {
        let row = CPListItem(text: item.title, detailText: item.author)
        row.handler = { [weak self] _, completion in
            completion() // acknowledge the tap immediately
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
        ApiClient.getData(from: url) { image in
            guard let image = image else { return }
            DispatchQueue.main.async { row.setImage(image) }
        }
    }
}
