import XCTest
@testable import Audiobookshelf

final class BrowseCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// (B) Within the TTL, a repeated read is served from cache and does NOT hit the network.
    func testFreshReadServedFromCacheWithoutRefetching() async {
        let cache = BrowseCache(ttl: 30)
        var fetches = 0
        let first = await cache.read("k", now: t0) { () async -> [Int]? in fetches += 1; return [1, 2] }
        let second = await cache.read("k", now: t0.addingTimeInterval(10)) { () async -> [Int]? in fetches += 1; return [9] }
        XCTAssertEqual(first, [1, 2])
        XCTAssertEqual(second, [1, 2], "within TTL the cached value is returned, not a re-fetch")
        XCTAssertEqual(fetches, 1, "the second read must not call fetch")
    }

    /// After the TTL expires, the value is re-fetched.
    func testStaleReadRefetches() async {
        let cache = BrowseCache(ttl: 30)
        var fetches = 0
        _ = await cache.read("k", now: t0) { () async -> [Int]? in fetches += 1; return [1] }
        let after = await cache.read("k", now: t0.addingTimeInterval(31)) { () async -> [Int]? in fetches += 1; return [2] }
        XCTAssertEqual(after, [2])
        XCTAssertEqual(fetches, 2)
    }

    /// (A) A failed fetch (nil) returns the last-good value instead of clobbering it with empty.
    func testFailureReturnsLastGood() async {
        let cache = BrowseCache(ttl: 30)
        _ = await cache.read("k", now: t0) { () async -> [Int]? in [1, 2, 3] }
        let onFailure = await cache.read("k", now: t0.addingTimeInterval(60)) { () async -> [Int]? in nil }
        XCTAssertEqual(onFailure, [1, 2, 3], "a failed refresh must preserve the last-good content")
    }

    /// A failure that never had a prior success returns nil (caller maps to empty).
    func testFailureWithNoPriorSuccessReturnsNil() async {
        let cache = BrowseCache(ttl: 30)
        let result: [Int]? = await cache.read("k", now: t0) { () async -> [Int]? in nil }
        XCTAssertNil(result)
    }

    /// A genuinely-empty SUCCESS ([]) is a valid cached value, distinct from a failure (nil):
    /// it is cached and served fresh, not treated as "no data".
    func testGenuineEmptySuccessIsCached() async {
        let cache = BrowseCache(ttl: 30)
        var fetches = 0
        let empty = await cache.read("k", now: t0) { () async -> [Int]? in fetches += 1; return [] }
        let again = await cache.read("k", now: t0.addingTimeInterval(5)) { () async -> [Int]? in fetches += 1; return [1] }
        XCTAssertEqual(empty, [])
        XCTAssertEqual(again, [], "empty success is cached within TTL and not re-fetched")
        XCTAssertEqual(fetches, 1)
    }

    /// A failed fetch is NOT cached, so the next read re-attempts (offline → recovery works).
    func testFailureIsNotCachedSoRecoveryRefetches() async {
        let cache = BrowseCache(ttl: 30)
        var fetches = 0
        let failed: [Int]? = await cache.read("k", now: t0) { () async -> [Int]? in fetches += 1; return nil }
        let recovered = await cache.read("k", now: t0.addingTimeInterval(1)) { () async -> [Int]? in fetches += 1; return [7] }
        XCTAssertNil(failed)
        XCTAssertEqual(recovered, [7], "after a failure the next read re-fetches even within the TTL window")
        XCTAssertEqual(fetches, 2)
    }

    /// Different keys are cached independently.
    func testKeysAreIndependent() async {
        let cache = BrowseCache(ttl: 30)
        let a = await cache.read("a", now: t0) { () async -> [Int]? in [1] }
        let b = await cache.read("b", now: t0) { () async -> [Int]? in [2] }
        XCTAssertEqual(a, [1])
        XCTAssertEqual(b, [2])
    }

    /// Two concurrent misses for the SAME key coalesce onto one fetch (429 prevention), and both
    /// callers receive the shared result.
    func testConcurrentMissesForSameKeyShareOneFetch() async {
        let cache = BrowseCache(ttl: 30)
        let counter = FetchCounter()
        async let a = cache.read("k", now: t0) { await counter.run() }
        async let b = cache.read("k", now: t0) { await counter.run() }
        let first = await a
        let second = await b
        XCTAssertEqual(first, [1])
        XCTAssertEqual(second, [1])
        let count = await counter.count
        XCTAssertEqual(count, 1, "concurrent misses for the same key must share a single fetch")
    }
}

/// Counts fetch invocations and suspends briefly so a concurrent read() for the same key reaches
/// the in-flight coalescing path before this fetch resolves.
private actor FetchCounter {
    private(set) var count = 0
    func run() async -> [Int]? {
        count += 1
        try? await Task.sleep(nanoseconds: 100_000_000)
        return [1]
    }
}
