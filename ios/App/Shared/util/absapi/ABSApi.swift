//
//  ABSApi.swift
//  Audiobookshelf
//
//  Facade for endpoints served by the generated ABSApiClient (strangler-fig migration off
//  ApiClient — see ios/ABSApiClient/MIGRATION.md). Each method fetches a DTO via the package's
//  operation wrappers and maps it to the Realm model the rest of the app expects. The app never
//  holds a generated `Client` (that would link OpenAPIRuntime into the app); all client
//  interaction stays in the package, which hands back plain DTOs.
//
//  Phase 2 (read-only): getCurrentUser, getMediaProgress. These are served ONLY by the generated
//  client — there is no legacy fallback.
//
//  NOTE (strict decoding): the generated decoder is strict, whereas the legacy MediaProgress used
//  `doubleOrStringDecoder` to tolerate numeric fields the server has historically returned as
//  strings. With no fallback, a server returning such a field as a string makes the fetch return
//  nil. Verify the target server returns real numbers for progress fields; if not, a tolerant
//  coding strategy is required.
//

import Foundation
import ABSApiClient

enum ABSApi {
    /// GET /api/me → Realm `User`, or nil on failure.
    static func getCurrentUser() async -> User? {
        guard let serverURL = ABSClientProvider.serverURL else {
            AbsLogger.error(message: "ABSApi.getCurrentUser: no server configured")
            return nil
        }
        guard let dto = await ABSApiClient.fetchCurrentUser(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher
        ) else {
            AbsLogger.error(message: "ABSApi.getCurrentUser: request failed")
            return nil
        }
        return User.from(dto: dto)
    }

    /// GET /api/me/progress/{id}[/{episodeId}] → Realm `MediaProgress`, or nil when there is no
    /// progress (404) or on failure.
    static func getMediaProgress(libraryItemId: String, episodeId: String?) async -> MediaProgress? {
        guard let serverURL = ABSClientProvider.serverURL else {
            AbsLogger.error(message: "ABSApi.getMediaProgress: no server configured")
            return nil
        }
        guard let dto = await ABSApiClient.fetchMediaProgress(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            libraryItemId: libraryItemId,
            episodeId: episodeId
        ) else {
            return nil
        }
        return MediaProgress.from(dto: dto)
    }
}
