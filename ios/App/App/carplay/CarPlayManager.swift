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

    /// Owns the Now Playing "Chapters" button + chapter list. Held so its observers stay alive.
    private var nowPlayingController: CarPlayNowPlayingController?

    /// The library whose "Recently Added" shelf feeds Home. Defaults to the first book library.
    var activeLibraryId: String?

    /// The in-flight Home reload, cancelled when a newer reload starts so a slow older one can't win.
    private var homeTask: Task<Void, Never>?

    /// Cover-loading tasks for the current Home render, cancelled when a newer rebuild starts.
    private var coverTasks: [Task<Void, Never>] = []

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
    }

    func start() {
        let library = CarPlayLibraryController(manager: self)
        self.libraryController = library
        self.nowPlayingController = CarPlayNowPlayingController(interfaceController: interfaceController)

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

    /// Tear down when the CarPlay scene disconnects: cancel in-flight work so it can't mutate stale
    /// templates or retain this manager, and detach the Now Playing observer (the shared template
    /// retains it, so it must be removed explicitly or it accumulates across reconnects).
    func stop() {
        homeTask?.cancel()
        homeTask = nil
        coverTasks.forEach { $0.cancel() }
        coverTasks.removeAll()
        nowPlayingController?.stop()
        nowPlayingController = nil
    }

    // MARK: - Home

    func rebuildHome() {
        homeTask?.cancel()
        // Cancel cover-loading tasks from a superseded rebuild so they can't apply to stale rows.
        coverTasks.forEach { $0.cancel() }
        coverTasks.removeAll()
        homeTask = Task { [weak self] in
            guard let self = self else { return }
            // activeLibraryId is mutated/read on the main actor, so touch it only via MainActor.run
            // to avoid a data race with this background Task.
            var libraryId = await MainActor.run { self.activeLibraryId }
            if libraryId == nil {
                let first = await BrowseApi.firstBookLibraryId()
                await MainActor.run { if self.activeLibraryId == nil { self.activeLibraryId = first } }
                libraryId = first
            }

            let continueListening = await BrowseApi.continueListening()
            var recentlyAdded: [BrowseItem] = []
            if let libraryId { recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId) }
            let downloads = BrowseApi.downloads()
            let libraryName = await self.activeLibraryName()
            if Task.isCancelled { return }

            // One shelf per non-empty source, each capped to the carousel max.
            struct Shelf { let title: String; let items: [BrowseItem] }
            let shelves: [Shelf] = [
                Shelf(title: "Continue Listening", items: continueListening),
                Shelf(title: libraryName.isEmpty ? "Recently Added" : "Recently Added · \(libraryName)", items: recentlyAdded),
                Shelf(title: "Downloads", items: downloads),
            ].filter { !$0.items.isEmpty }
                .map { Shelf(title: $0.title, items: Array($0.items.prefix(Int(CPMaximumNumberOfGridImages)))) }

            // Build rows with placeholders first so Home appears immediately, then fill covers per shelf.
            await MainActor.run {
                if Task.isCancelled { return }
                guard !shelves.isEmpty else {
                    self.homeTemplate.updateSections([CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)])])
                    return
                }
                let rows: [CPListImageRowItem] = shelves.map { shelf in
                    CarPlayCarousel.make(title: shelf.title, items: shelf.items) { [weak self] index in
                        guard shelf.items.indices.contains(index) else { return }
                        let item = shelf.items[index]
                        Task { @MainActor in
                            BrowsePlaybackStarter.play(item) {
                                self?.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                            }
                        }
                    }
                }
                self.homeTemplate.updateSections([CPListSection(items: rows)])

                // Load covers off the main actor, then apply to each row once its shelf is ready.
                // Tracked in coverTasks so a superseding rebuildHome() cancels them (see method top).
                for (shelf, row) in zip(shelves, rows) {
                    let task = Task { [weak self] in
                        guard let self else { return }
                        var covers: [UIImage?] = []
                        for item in shelf.items {
                            if Task.isCancelled { return }
                            covers.append(await self.carouselCover(for: item))
                        }
                        if Task.isCancelled { return }
                        await MainActor.run {
                            CarPlayCarousel.applyCovers(covers, to: row, titles: shelf.items.map { $0.title })
                        }
                    }
                    self.coverTasks.append(task)
                }
            }
        }
    }

    /// The display name of the active library, for the "Recently Added · <name>" header. Empty if unknown.
    private func activeLibraryName() async -> String {
        let id = await MainActor.run { self.activeLibraryId }
        guard let id else { return "" }
        return await BrowseApi.bookLibraries().first(where: { $0.id == id })?.name ?? ""
    }

    // MARK: - Covers

    /// Sized cover images keyed by cover URL. Home rebuilds recreate rows frequently (scene
    /// reactivation, library switches); without this, every rebuild re-requests every cover, and
    /// the cover endpoint is rate-limited — a burst returns 429 and the covers blank out. Caching
    /// the sized image means a cover is fetched at most once and reused thereafter.
    private static let coverCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Fetch (or reuse from cache) the carousel-sized cover for one item. Returns nil if there is no
    /// cover URL or the request fails; callers substitute a placeholder.
    private func carouselCover(for item: BrowseItem) async -> UIImage? {
        guard let url = item.coverURL else { return nil }
        // Suffix the key so carousel-sized covers don't collide with any differently-sized covers.
        let key = "\(url.absoluteString)#carousel" as NSString
        if let cached = Self.coverCache.object(forKey: key) { return cached }
        let image: UIImage? = await withCheckedContinuation { continuation in
            ApiClient.getData(from: url) { continuation.resume(returning: $0) }
        }
        guard let image else { return nil }
        let sized = await MainActor.run { self.sizedCarouselCover(image) }
        Self.coverCache.setObject(sized, forKey: key)
        return sized
    }

    /// Crop to a centered square and resize to the CarPlay image-row max at the car's display scale.
    /// Sizes to CarPlayCarousel.maximumImageSize (the image-row max, not the list-item max) and runs
    /// on the main actor because it reads the main-thread-only carTraitCollection.
    @MainActor
    private func sizedCarouselCover(_ image: UIImage) -> UIImage {
        let maxPoints = CarPlayCarousel.maximumImageSize
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
