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

    // MARK: - Writes (Phase 3)

    /// PATCH /api/me/progress/{libraryItemId}[/{episodeId}] with a partial progress update.
    /// Returns true on a 2xx response.
    public static func updateMediaProgress(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing,
        libraryItemId: String,
        episodeId: String?,
        update: Components.Schemas.mediaProgressUpdate
    ) async -> Bool {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            if let episodeId, !episodeId.isEmpty {
                let output = try await client.updatePodcastEpisodeMediaProgress(
                    .init(path: .init(libraryItemId: libraryItemId, episodeId: episodeId), body: .json(update))
                )
                if case .ok = output { return true }
                return false
            } else {
                let output = try await client.updateMediaProgress(
                    .init(path: .init(libraryItemId: libraryItemId), body: .json(update))
                )
                if case .ok = output { return true }
                return false
            }
        } catch {
            return false
        }
    }

    /// POST /api/session/{sessionId}/sync — heartbeat for an open server session.
    public static func syncPlaybackSession(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing,
        sessionId: String,
        report: Components.Schemas.playbackReport
    ) async -> Bool {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            let output = try await client.syncPlaybackSession(.init(path: .init(id: sessionId), body: .json(report)))
            if case .ok = output { return true }
            return false
        } catch {
            return false
        }
    }

    /// POST /api/session/local — sync a single locally-recorded session.
    public static func syncLocalPlaybackSession(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing,
        session: Components.Schemas.playbackSession
    ) async -> Bool {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            let output = try await client.syncLocalPlaybackSession(.init(body: .json(session)))
            if case .ok = output { return true }
            return false
        } catch {
            return false
        }
    }

    /// POST /api/session/local-all — bulk-sync offline sessions accumulated while disconnected.
    public static func syncAllLocalPlaybackSessions(
        serverURL: URL,
        accessToken: @escaping @Sendable () -> String?,
        refresher: any ABSTokenRefreshing,
        body: Components.Schemas.localPlaybackSessionSyncAll
    ) async -> Bool {
        let client = makeRefreshAwareClient(serverURL: serverURL, accessToken: accessToken, refresher: refresher)
        do {
            let output = try await client.syncAllLocalPlaybackSessions(.init(body: .json(body)))
            if case .ok = output { return true }
            return false
        } catch {
            return false
        }
    }
}
