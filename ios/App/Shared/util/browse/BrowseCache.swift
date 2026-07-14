//
//  BrowseCache.swift
//  App
//
//  Short-lived, last-good cache for the server-backed CarPlay browse reads. It serves two jobs:
//
//   - Fewer server hits (avoids 429): CarPlay fires browse reads from many triggers — scene
//     reactivation, tab select, and every library-row tap — with no natural coalescing. Within
//     `ttl` a repeated read returns the cached value WITHOUT a request, so bursty navigation can't
//     stampede the server into rate-limiting.
//
//   - Never clobber good content: a fetch failure (nil — network/non-2xx/rate-limit) returns the
//     last successful value instead of an empty list, so a transient failure doesn't blank the
//     CarPlay UI. Only successes are cached, so an offline read recovers on the next attempt.
//
//  The fetch closure returns nil on failure and a value (possibly an empty array) on success — that
//  nil-vs-empty distinction is what lets the cache tell "the request failed" from "there is no data".
//

import Foundation

actor BrowseCache {
    static let shared = BrowseCache()

    let ttl: TimeInterval
    private var entries: [String: (value: Any, storedAt: Date)] = [:]

    init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    /// Return the cached value for `key` when it is still fresh; otherwise run `fetch`. On success
    /// the value is cached and returned; on failure (nil) the last-good value is returned (even if
    /// stale), or nil if there has never been a success for this key.
    func read<T>(_ key: String, now: Date = Date(), fetch: () async -> T?) async -> T? {
        if let entry = entries[key], now.timeIntervalSince(entry.storedAt) < ttl, let value = entry.value as? T {
            return value
        }
        if let fetched = await fetch() {
            entries[key] = (fetched, now)
            return fetched
        }
        return entries[key]?.value as? T
    }

    /// Drop all cached entries (e.g. on logout / server switch).
    func clear() {
        entries.removeAll()
    }
}
