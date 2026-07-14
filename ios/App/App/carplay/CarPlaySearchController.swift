//
//  CarPlaySearchController.swift
//  App
//
//  The CarPlay "Search" tab. The tab itself is a CPListTemplate with a single "Search" row that
//  presents a CPSearchTemplate (CPSearchTemplate cannot be a tab). Results reuse the manager's
//  shared row mapper and honor maximumItemCount.
//

import CarPlay

final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    let template: CPListTemplate
    private weak var manager: CarPlayManager?
    private let searchTemplate = CPSearchTemplate()

    init(manager: CarPlayManager) {
        self.manager = manager
        let entry = CPListItem(text: "Search", detailText: nil)
        self.template = CPListTemplate(title: "Search", sections: [CPListSection(items: [entry])])
        super.init()
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        searchTemplate.delegate = self
        entry.handler = { [weak self] _, completion in
            completion()
            guard let self = self else { return }
            self.manager?.interfaceController.pushTemplate(self.searchTemplate, animated: true, completion: nil)
        }
    }

    private var pendingSearch: Task<Void, Never>?

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        pendingSearch?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { completionHandler([]); return }
        let libraryId = manager?.activeLibraryId
        pendingSearch = Task { [weak self] in
            // Real debounce: wait a beat; a newer keystroke cancels this before any network work.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let results = await BrowseApi.search(query: query, libraryId: libraryId)
            let capped = Array(results.prefix(CPListTemplate.maximumItemCount))
            // Build rows and deliver on the main thread (CPListItem is main-thread-only); re-check
            // cancellation after the hop so a superseded search never delivers stale results. When
            // cancelled we simply don't call this completionHandler — the superseding call owns a
            // fresh handler that CarPlay uses instead.
            await MainActor.run {
                if Task.isCancelled { return }
                let rows = capped.map { self?.manager?.makeRow($0) ?? CPListItem(text: $0.title, detailText: $0.author) }
                completionHandler(rows)
            }
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        // Row handlers (from makeRow) already start playback + push Now Playing.
        if let handler = item.handler {
            handler(item, completionHandler)
        } else {
            completionHandler()
        }
    }
}
