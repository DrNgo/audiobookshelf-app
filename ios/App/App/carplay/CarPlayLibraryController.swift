//
//  CarPlayLibraryController.swift
//  App
//
//  The CarPlay "Library" tab: lists the server's book libraries; selecting one switches which
//  library feeds Home's Recently Added shelf. Offline/error shows a single disabled row; Home
//  still works from Downloads.
//

import CarPlay

final class CarPlayLibraryController {
    let template = CPListTemplate(title: "Library", sections: [])
    private weak var manager: CarPlayManager?

    init(manager: CarPlayManager) {
        self.manager = manager
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "books.vertical")
        reload()
    }

    func reload() {
        Task { [weak self] in
            let libraries = await BrowseApi.bookLibraries()
            // Build CarPlay template objects on the main thread (CPListItem is main-thread-only).
            await MainActor.run {
                guard let self = self else { return }
                let items: [CPListItem] = libraries.prefix(CPListTemplate.maximumItemCount).map { library in
                    let row = CPListItem(text: library.name, detailText: nil)
                    row.handler = { [weak self] _, completion in
                        completion()
                        self?.manager?.activeLibraryId = library.id
                        self?.manager?.rebuildHome()
                    }
                    return row
                }
                let section = items.isEmpty
                    ? CPListSection(items: [CPListItem(text: "Libraries unavailable", detailText: nil)])
                    : CPListSection(items: items)
                self.template.updateSections([section])
            }
        }
    }
}
