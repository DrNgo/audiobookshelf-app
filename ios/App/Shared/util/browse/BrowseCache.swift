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
    /// Fetches currently in flight, keyed by cache key. Concurrent misses for the same key share the
    /// one request instead of each hitting the server (which the rate limiter punishes with a 429).
    private var inFlight: [String: Task<Any?, Never>] = [:]

    init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    /// Return the cached value for `key` when it is still fresh; otherwise run `fetch` (coalescing
    /// with any fetch already in flight for the same key). On success the value is cached and
    /// returned; on failure (nil) the last-good value is returned (even if stale), or nil if there
    /// has never been a success for this key.
    func read<T>(_ key: String, now: Date = Date(), fetch: @escaping () async -> T?) async -> T? {
        if let entry = entries[key], now.timeIntervalSince(entry.storedAt) < ttl, let value = entry.value as? T {
            return value
        }
        // Coalesce concurrent misses for the same key onto a single fetch. `.map { $0 as Any }`
        // erases T to Any without nesting the optional, so a nil (failure) stays nil.
        let fetched: Any?
        if let existing = inFlight[key] {
            fetched = await existing.value
        } else {
            let task = Task<Any?, Never> { await fetch().map { $0 as Any } }
            inFlight[key] = task
            fetched = await task.value
            inFlight[key] = nil
        }
        if let value = fetched as? T {
            entries[key] = (value, now)
            return value
        }
        return entries[key]?.value as? T
    }

    /// Drop all cached entries (e.g. on logout / server switch).
    func clear() {
        entries.removeAll()
    }
}
