//
//  CarPlayManager.swift
//  App
//
//  Builds and drives the CarPlay UI: Home is the root (Continue Listening / Recently Added /
//  Downloads), with a top-bar library-picker button that pushes the library list to switch which
//  server library feeds Recently Added. Server sections are best-effort — offline they are omitted,
//  leaving the always-available Downloads section.
//

import CarPlay
import UIKit

final class CarPlayManager: NSObject {
    let interfaceController: CPInterfaceController
    private let homeTemplate = CPListTemplate(title: "Home", sections: [])

    private var libraryController: CarPlayLibraryController?

    /// The library whose "Recently Added" shelf feeds Home. Defaults to the first book library.
    var activeLibraryId: String?

    /// The in-flight Home reload, cancelled when a newer reload starts so a slow older one can't win.
    private var homeTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
    }

    func start() {
        let library = CarPlayLibraryController(manager: self)
        self.libraryController = library

        homeTemplate.trailingNavigationBarButtons = [
            CPBarButton(image: UIImage(systemName: "books.vertical") ?? UIImage()) { [weak self] _ in
                self?.presentLibraryPicker()
            }
        ]
        interfaceController.setRootTemplate(homeTemplate, animated: false, completion: nil)
        rebuildHome()
    }

    /// Push the library picker on top of Home. Selecting a library pops back (see CarPlayLibraryController).
    func presentLibraryPicker() {
        guard let library = libraryController else { return }
        // Guard against double-taps re-pushing the same template.
        guard interfaceController.topTemplate !== library.template else { return }
        library.reload()
        interfaceController.pushTemplate(library.template, animated: true) { ok, error in
            if !ok { AbsLogger.error(message: "CarPlay: pushTemplate(library) failed: \(String(describing: error))") }
        }
    }

    /// Re-fetch all server-backed content. Called when the CarPlay scene becomes active again so a
    /// drive that started offline recovers its Home sections once connectivity returns. The library
    /// picker reloads itself when opened, so only Home needs refreshing here.
    func refresh() {
        rebuildHome()
    }

    // MARK: - Home

    func rebuildHome() {
        homeTask?.cancel()
        homeTask = Task { [weak self] in
            guard let self = self else { return }
            // activeLibraryId is mutated from the main actor (Library tab) and read there (Search),
            // so touch it only via MainActor.run to avoid a data race with this background Task.
            var libraryId = await MainActor.run { self.activeLibraryId }
            if libraryId == nil {
                let first = await BrowseApi.firstBookLibraryId()
                await MainActor.run { if self.activeLibraryId == nil { self.activeLibraryId = first } }
                libraryId = first
            }
            let continueListening = await BrowseApi.continueListening()
            var recentlyAdded: [BrowseItem] = []
            if let libraryId = libraryId {
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

    /// Sized cover images keyed by cover URL. Home rebuilds recreate rows frequently (scene
    /// reactivation, tab/library taps); without this, every rebuild re-requests every cover, and
    /// the cover endpoint is rate-limited — a burst returns 429 and the covers blank out. Caching
    /// the sized image means a cover is fetched at most once and reused thereafter.
    private static let coverCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    private func loadCover(_ item: BrowseItem, into row: CPListItem) {
        guard let url = item.coverURL else { return }
        let key = url.absoluteString as NSString
        if let cached = Self.coverCache.object(forKey: key) {
            row.setImage(cached)
            return
        }
        ApiClient.getData(from: url) { [weak self] image in
            guard let self, let image = image else { return }
            let sized = self.sizedCover(image)
            Self.coverCache.setObject(sized, forKey: key)
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
