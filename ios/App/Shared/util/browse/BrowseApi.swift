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
    /// "Continue Listening" — the user's in-progress items (server, user-wide).
    static func continueListening(limit: Int = 25) async -> [BrowseItem] {
        guard let config = ABSClientProvider.config else { return [] }
        guard let data = await ABSApiClient.fetchItemsInProgressData(config: config, limit: limit) else { return [] }
        return BrowseItem.fromItemsInProgress(data: data, serverAddress: Store.serverConfig?.address)
    }

    /// "Recently Added" — the recently-added shelf of a library's personalized view (server).
    static func recentlyAdded(libraryId: String, limit: Int = 10) async -> [BrowseItem] {
        guard let config = ABSClientProvider.config else { return [] }
        guard let data = await ABSApiClient.fetchPersonalizedShelvesData(config: config, libraryId: libraryId, limit: limit) else { return [] }
        return BrowseItem.fromPersonalizedRecentlyAdded(data: data, serverAddress: Store.serverConfig?.address)
    }

    /// "Downloads" — books available offline on the device. Always works (no network).
    static func downloads() -> [BrowseItem] {
        Database.shared.getLocalLibraryItems()
            .filter { $0.mediaType == "book" }
            .map { BrowseItem.from(local: $0) }
    }

    /// The id of the user's first book library — used to scope the "Recently Added" shelf.
    /// Nil if there is no book library or the request fails.
    static func firstBookLibraryId() async -> String? {
        guard let config = ABSClientProvider.config else { return nil }
        guard let data = await ABSApiClient.fetchLibrariesData(config: config) else { return nil }
        struct Library: Decodable { let id: String?; let mediaType: String? }
        struct Response: Decodable { let libraries: [Library]? }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return resp.libraries?.first(where: { $0.mediaType == "book" })?.id
    }

    /// Search the first book library for `query` and return matching books. [] on failure/no library.
    static func search(query: String, limit: Int = 12) async -> [BrowseItem] {
        guard let config = ABSClientProvider.config else { return [] }
        guard let libraryId = await firstBookLibraryId() else { return [] }
        guard let data = await ABSApiClient.fetchLibrarySearchData(config: config, libraryId: libraryId, query: query, limit: limit) else { return [] }
        return BrowseItem.fromSearch(data: data, serverAddress: Store.serverConfig?.address)
    }
}
