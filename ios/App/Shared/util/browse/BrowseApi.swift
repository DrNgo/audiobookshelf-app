//
//  BrowseApi.swift
//  App
//
//  Native browse data access for CarPlay (and future SDK-dependent surfaces). Fetches the browse
//  endpoints through the generated ABSApiClient and maps them into BrowseItem view models.
//  Server sources return [] on ANY failure (offline, non-2xx, decode) so the CarPlay UI can always
//  fall back to the on-device Downloads section.
//

import Foundation
import ABSApiClient

enum BrowseApi {
    /// Scope every cache key to the active server connection so a failed fetch after a server switch
    /// can't hand back the previous server's last-good data. Falls back to a stable token when no
    /// server is configured (the fetch fails anyway, so nothing is cached under it).
    private static func cacheKey(_ suffix: String) -> String {
        "\(Store.serverConfig?.id ?? "none"):\(suffix)"
    }

    /// "Continue Listening" — the user's in-progress items (server, user-wide).
    /// Cached: a burst of CarPlay refreshes reuses the last result instead of re-hitting the server,
    /// and a failed fetch keeps the last-good list rather than blanking the shelf. See BrowseCache.
    static func continueListening(limit: Int = 25) async -> [BrowseItem] {
        await BrowseCache.shared.read(cacheKey("continueListening")) {
            guard let config = ABSClientProvider.config else { return nil }
            guard let data = await ABSApiClient.fetchItemsInProgressData(config: config, limit: limit) else { return nil }
            return BrowseItem.fromItemsInProgress(data: data, serverAddress: Store.serverConfig?.address)
        } ?? []
    }

    /// "Recently Added" — the recently-added shelf of a library's personalized view (server).
    /// Cached per library id (see continueListening for the why).
    static func recentlyAdded(libraryId: String, limit: Int = 10) async -> [BrowseItem] {
        await BrowseCache.shared.read(cacheKey("recentlyAdded:\(libraryId)")) {
            guard let config = ABSClientProvider.config else { return nil }
            guard let data = await ABSApiClient.fetchPersonalizedShelvesData(config: config, libraryId: libraryId, limit: limit) else { return nil }
            return BrowseItem.fromPersonalizedRecentlyAdded(data: data, serverAddress: Store.serverConfig?.address)
        } ?? []
    }

    /// "Downloads" — books available offline on the device. Always works (no network).
    static func downloads() -> [BrowseItem] {
        Database.shared.getLocalLibraryItems()
            .filter { $0.mediaType == "book" }
            .map { BrowseItem.from(local: $0) }
    }

    /// The id of the user's first book library — used to scope the "Recently Added" shelf.
    /// Derived from the cached `bookLibraries()` so it shares one request (and one cache entry)
    /// with the Library tab instead of firing its own /api/libraries call. Nil if there is no book
    /// library or the request fails.
    static func firstBookLibraryId() async -> String? {
        await bookLibraries().first?.id
    }

    /// The user's book libraries (id + name) for the CarPlay Library tab. [] on failure.
    /// Cached: the Library tab and firstBookLibraryId share this single /api/libraries read, and a
    /// failed fetch preserves the last-good list rather than emptying the tab. See BrowseCache.
    static func bookLibraries() async -> [BrowseLibrary] {
        await BrowseCache.shared.read(cacheKey("libraries")) {
            guard let config = ABSClientProvider.config else { return nil }
            guard let data = await ABSApiClient.fetchLibrariesData(config: config) else { return nil }
            return BrowseLibrary.fromLibraries(data: data)
        } ?? []
    }

    /// Search `libraryId` (or the first book library when nil) for `query` and return matching books.
    /// [] on failure/no library. CarPlay passes the user's active library; App Intents pass nil.
    static func search(query: String, libraryId: String? = nil, limit: Int = 12) async -> [BrowseItem] {
        guard let config = ABSClientProvider.config else { return [] }
        var resolvedLibraryId = libraryId
        if resolvedLibraryId == nil { resolvedLibraryId = await firstBookLibraryId() }
        guard let libraryId = resolvedLibraryId else { return [] }
        guard let data = await ABSApiClient.fetchLibrarySearchData(config: config, libraryId: libraryId, query: query, limit: limit) else { return [] }
        return BrowseItem.fromSearch(data: data, serverAddress: Store.serverConfig?.address)
    }
}
