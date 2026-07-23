//
//  CaptionContextStore.swift
//  Audiobookshelf
//
//  Persists the biasing vocabulary as context.json inside the item's download
//  folder, so it is evicted with the download (mirrors CaptionStore). load()
//  never throws — a missing/corrupt/stale file degrades to no bias.
//

import Foundation

final class CaptionContextStore {

    private static let schemaVersion = 1
    private static let filename = "context.json"

    private struct Payload: Codable {
        let version: Int
        let terms: [String]
    }

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    init(directory: URL) { self.directory = directory }

    func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.schemaVersion
        else { return [] }
        return payload.terms
    }

    func save(_ terms: [String]) throws {
        let payload = Payload(version: Self.schemaVersion, terms: terms)
        let data = try JSONEncoder().encode(payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    func evict() { try? FileManager.default.removeItem(at: fileURL) }
}
