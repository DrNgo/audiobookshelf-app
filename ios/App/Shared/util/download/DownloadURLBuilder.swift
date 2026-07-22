//
//  DownloadURLBuilder.swift
//  Audiobookshelf
//
//  Builds download URLs from a server path, against the CURRENT server config.
//

import Foundation

enum DownloadURLBuilder {

    /// The API path that serves an audio track's file.
    static func trackPath(itemId: String, ino: String) -> String {
        "/api/items/\(itemId)/file/\(ino)/download"
    }

    /// Build a download URL for a part.
    ///
    /// Two bugs live here, both of which broke exactly the case where a download has to be restarted
    /// from the database — i.e. any book big enough to be interrupted:
    ///
    /// 1. Track parts persisted `Store.serverConfig.address` as their `serverPath`, while ebook and
    ///    cover parts persisted a real API path. The stored URI was therefore `address + address`,
    ///    which parses to the nonexistent host "<host>https". Since the download session sets
    ///    `waitsForConnectivity = true`, URLSession did not fail fast on the unreachable host — it
    ///    waited, so the transfer sat at zero bytes until the stall watchdog cancelled and retried it
    ///    against the same dead URL, forever. `contentUrlFallback` repairs those existing records.
    ///
    /// 2. The URI baked in the access token at creation time. Tokens are short-lived JWTs now, so a
    ///    download reconciled hours later presented an expired one. The token is passed in here from
    ///    the current config instead.
    static func url(address: String, token: String, serverPath: String?, contentUrlFallback: String?) -> URL? {
        guard var path = serverPath else { return nil }

        // A valid server path is relative. Anything else is a corrupt legacy record.
        if !path.hasPrefix("/") {
            guard let fallback = contentUrlFallback, fallback.hasPrefix("/") else { return nil }
            path = fallback.hasSuffix("/download") ? fallback : "\(fallback)/download"
        }

        let base = address.hasSuffix("/") ? String(address.dropLast()) : address
        var urlString = "\(base)\(path)?token=\(token)"
        if path.hasSuffix("/cover") {
            urlString += "&format=jpeg" // For cover images force to jpeg
        }
        return URL(string: urlString)
    }
}
