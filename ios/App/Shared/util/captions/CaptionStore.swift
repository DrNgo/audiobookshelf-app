//
//  CaptionStore.swift
//  Audiobookshelf
//
//  Persists caption segments as a single JSON file inside the item's existing
//  download folder, so deleting a download deletes its captions for free.
//

import Foundation

final class CaptionStore {

    private static let schemaVersion = 1
    private static let filename = "captions.json"

    private struct Payload: Codable {
        let version: Int
        let locale: String
        let segments: [CaptionSegment]
    }

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Cached segments for `locale`, or `[]` when absent, stale, or unreadable.
    /// Never throws — a broken cache degrades to re-transcription, not a crash.
    func load(locale: String) -> [CaptionSegment] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.schemaVersion,
              payload.locale == locale
        else { return [] }
        return payload.segments
    }

    /// Merge `segments` into the cache. A locale change discards the old cache
    /// rather than mixing languages.
    func append(_ segments: [CaptionSegment], locale: String) throws {
        var merged = load(locale: locale)

        var seenStarts = Set(merged.map { Self.key($0.start) })
        for segment in segments where !seenStarts.contains(Self.key(segment.start)) {
            seenStarts.insert(Self.key(segment.start))
            merged.append(segment)
        }
        merged.sort { $0.start < $1.start }

        let payload = Payload(version: Self.schemaVersion, locale: locale, segments: merged)
        let data = try JSONEncoder().encode(payload)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    func evict() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Millisecond-quantised start time, so float noise can't defeat dedup.
    private static func key(_ time: Double) -> Int {
        Int((time * 1000).rounded())
    }
}
