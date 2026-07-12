//
//  ABSApiClientOperations.swift
//  ABSApiClient
//
//  High-level, app-friendly wrappers around the generated operations. They build a
//  refresh-aware client internally and return plain DTOs (Components.Schemas.*), so the app can
//  call them without ever holding a `Client` or otherwise linking OpenAPIRuntime symbols into
//  its own object files. The app maps the returned DTOs to its Realm models.
//
//  Each wrapper returns nil on any failure (network, non-2xx, or strict-decode) so the caller
//  can fall back to the legacy ApiClient during the migration.
//

import Foundation

extension ABSApiClient {
    /// GET /api/me — returns the minimal user DTO, or nil on failure.
    public static func fetchCurrentUser(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing
    ) async -> Components.Schemas.userMinimal? {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            let output = try await client.getCurrentUser()
            guard case let .ok(ok) = output else { return nil }
            return try ok.body.json
        } catch {
            return nil
        }
    }

    /// GET /api/me/progress/{libraryItemId}[/{episodeId}] — returns the media progress DTO, or
    /// nil when there is no progress (404) or on failure.
    public static func fetchMediaProgress(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing,
        libraryItemId: String,
        episodeId: String?
    ) async -> Components.Schemas.mediaProgress? {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            if let episodeId, !episodeId.isEmpty {
                let output = try await client.getPodcastEpisodeMediaProgress(
                    .init(path: .init(libraryItemId: libraryItemId, episodeId: episodeId))
                )
                guard case let .ok(ok) = output else { return nil }
                return try ok.body.json
            } else {
                let output = try await client.getMediaProgress(
                    .init(path: .init(libraryItemId: libraryItemId))
                )
                guard case let .ok(ok) = output else { return nil }
                return try ok.body.json
            }
        } catch {
            return nil
        }
    }
}
