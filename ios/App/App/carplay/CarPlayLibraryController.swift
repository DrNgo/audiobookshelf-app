//
//  CarPlayLibraryController.swift
//  App
//
//  The CarPlay library picker: pushed from Home's top-bar button, it lists the server's book
//  libraries; selecting one switches which library feeds Home's Recently Added shelf and pops back
//  to Home. Offline/error shows a single disabled row; Home still works from Downloads.
//

import CarPlay

final class CarPlayLibraryController {
    let template = CPListTemplate(title: "Library", sections: [])
    private weak var manager: CarPlayManager?

    init(manager: CarPlayManager) {
        self.manager = manager
        reload()
    }

    func reload() {
        Task { [weak self] in
            let libraries = await BrowseApi.bookLibraries()
            // Build CarPlay template objects on the main thread (CPListItem is main-thread-only).
            await MainActor.run {
                guard let self = self else { return }
                // The library feeding Home. Falls back to the first library because that is what
                // rebuildHome() defaults to when no library has been explicitly chosen yet — so the
                // checkmark matches the shelf that is actually showing.
                let activeId = self.manager?.activeLibraryId ?? libraries.first?.id
                let items: [CPListItem] = libraries.prefix(CPListTemplate.maximumItemCount).map { library in
                    // Explicit, code-controlled "active library" indicator (a checkmark accessory),
                    // so selection state does not depend on CarPlay's row-focus highlight.
                    // accessoryImage is get-only, so it must be supplied at construction.
                    let checkmark = library.id == activeId ? UIImage(systemName: "checkmark") : nil
                    let row = CPListItem(text: library.name, detailText: nil, image: nil,
                                         accessoryImage: checkmark, accessoryType: .none)
                    row.handler = { [weak self] _, completion in
                        completion()
                        self?.manager?.activeLibraryId = library.id
                        self?.manager?.rebuildHome()
                        // Refresh so the checkmark moves to the newly selected library. bookLibraries()
                        // is cached, so this re-render makes no extra server request.
                        self?.reload()
                        // Return to Home now that the active library changed.
                        self?.manager?.interfaceController.popTemplate(animated: true, completion: nil)
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
