//
//  MediaProgressMapping.swift
//  Audiobookshelf
//
//  Phase 1 of the ABSApiClient migration. Bridges the generated Codable DTO
//  (Components.Schemas.mediaProgress) to/from the Realm-backed MediaProgress model.
//

import Foundation
import ABSApiClient

extension MediaProgress {
    /// Build an *unmanaged* Realm MediaProgress from the generated DTO. The caller is
    /// responsible for persisting it inside a write transaction.
    static func from(dto: Components.Schemas.mediaProgress) -> MediaProgress {
        let mp = MediaProgress()
        mp.id = dto.id ?? ""
        mp.userId = dto.userId ?? ""
        mp.libraryItemId = dto.libraryItemId ?? ""
        mp.episodeId = dto.episodeId
        mp.duration = dto.duration ?? 0
        mp.progress = dto.progress ?? 0
        mp.currentTime = dto.currentTime ?? 0
        mp.isFinished = dto.isFinished ?? false
        mp.ebookLocation = dto.ebookLocation
        mp.ebookProgress = dto.ebookProgress
        // DTO timestamps are Int (ms since epoch); Realm stores them as Double.
        mp.lastUpdate = Double(dto.lastUpdate ?? 0)
        mp.startedAt = Double(dto.startedAt ?? 0)
        mp.finishedAt = dto.finishedAt.map(Double.init)
        return mp
    }

    /// Produce the generated DTO from this Realm MediaProgress.
    func toDTO() -> Components.Schemas.mediaProgress {
        Components.Schemas.mediaProgress(
            id: id,
            userId: userId,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            duration: duration,
            progress: progress,
            currentTime: currentTime,
            isFinished: isFinished,
            ebookLocation: ebookLocation,
            ebookProgress: ebookProgress,
            lastUpdate: Int(lastUpdate),
            startedAt: Int(startedAt),
            finishedAt: finishedAt.map { Int($0) }
        )
    }
}
