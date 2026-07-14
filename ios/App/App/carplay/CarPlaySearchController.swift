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

    // Debounce so we don't fire a search per keystroke.
    private var pendingSearch: Task<Void, Never>?

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        pendingSearch?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { completionHandler([]); return }
        pendingSearch = Task {
            let results = await BrowseApi.search(query: query)
            let capped = Array(results.prefix(CPListTemplate.maximumItemCount))
            if Task.isCancelled { return }
            let rows = await MainActor.run {
                capped.map { self.manager?.makeRow($0) ?? CPListItem(text: $0.title, detailText: $0.author) }
            }
            completionHandler(rows)
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
