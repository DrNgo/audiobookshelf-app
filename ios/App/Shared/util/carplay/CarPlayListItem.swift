//
//  CarPlayListItem.swift
//  App
//
//  A minimal, framework-agnostic view model for one browsable audiobook row in CarPlay.
//  Kept pure and Equatable so the mapping from server browse JSON / local items can be
//  unit-tested without importing the CarPlay framework or standing up Realm.
//

import Foundation

struct CarPlayListItem: Equatable {
    /// The server library item id, or — when `isLocal` — the local library item id. The playback
    /// starter branches on `isLocal` to decide how to begin a session.
    let id: String
    let title: String
    let author: String?
    let isLocal: Bool
    let coverURL: URL?
}

extension CarPlayListItem {
    // MARK: - Server browse decode
    //
    // Lenient decoders over the minified library item shape. Every field is optional; a row with
    // no usable id is dropped rather than surfaced.

    private struct MinifiedItem: Decodable {
        let id: String?
        let media: Media?
        struct Media: Decodable {
            let metadata: Meta?
            let coverPath: String?
        }
        struct Meta: Decodable {
            let title: String?
            let authorName: String?
        }
    }

    private struct ItemsInProgressResponse: Decodable {
        let libraryItems: [MinifiedItem]?
    }

    private struct Shelf: Decodable {
        let id: String?
        let entities: [MinifiedItem]?
    }

    /// Map `GET /api/me/items-in-progress` (`{ libraryItems: [...] }`) into rows. [] on decode failure.
    static func fromItemsInProgress(data: Data, serverAddress: String?) -> [CarPlayListItem] {
        guard let resp = try? JSONDecoder().decode(ItemsInProgressResponse.self, from: data) else { return [] }
        return (resp.libraryItems ?? []).compactMap { serverRow($0, serverAddress: serverAddress) }
    }

    /// Map `GET /api/libraries/{id}/personalized` (an array of shelves) into the "recently-added"
    /// shelf's rows. [] on decode failure or if the shelf is absent.
    static func fromPersonalizedRecentlyAdded(data: Data, serverAddress: String?) -> [CarPlayListItem] {
        guard let shelves = try? JSONDecoder().decode([Shelf].self, from: data) else { return [] }
        guard let shelf = shelves.first(where: { $0.id == "recently-added" }) else { return [] }
        return (shelf.entities ?? []).compactMap { serverRow($0, serverAddress: serverAddress) }
    }

    private static func serverRow(_ item: MinifiedItem, serverAddress: String?) -> CarPlayListItem? {
        guard let id = item.id, !id.isEmpty else { return nil }
        let hasCover = item.media?.coverPath?.isEmpty == false
        return CarPlayListItem(
            id: id,
            title: item.media?.metadata?.title ?? "Unknown Title",
            author: item.media?.metadata?.authorName,
            isLocal: false,
            coverURL: coverURL(libraryItemId: id, hasCover: hasCover, serverAddress: serverAddress)
        )
    }

    /// Build the server cover URL. Forces `format=jpeg` because `UIImage(data:)` decodes the server's
    /// default WebP unreliably. Nil when the item has no cover or no server address is known.
    static func coverURL(libraryItemId: String, hasCover: Bool, serverAddress: String?) -> URL? {
        guard hasCover, let address = serverAddress, !address.isEmpty else { return nil }
        return URL(string: "\(address)/api/items/\(libraryItemId)/cover?format=jpeg")
    }

    // MARK: - Local (downloaded) item

    /// Map a downloaded item. Reads the on-disk cover; always `isLocal`.
    static func from(local item: LocalLibraryItem) -> CarPlayListItem {
        CarPlayListItem(
            id: item.id,
            title: item.media?.metadata?.title ?? "Unknown Title",
            author: item.media?.metadata?.authorName,
            isLocal: true,
            coverURL: item.coverUrl
        )
    }
}
