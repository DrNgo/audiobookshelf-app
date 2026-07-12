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
import UIKit
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

    // MARK: - Writes (Phase 3)

    /// PATCH /api/me/progress/{id}[/{ep}]. The generic payload (e.g. ["isFinished": true]) is
    /// re-encoded into the typed mediaProgressUpdate DTO. Returns true on success.
    static func updateMediaProgress<T: Encodable>(libraryItemId: String, episodeId: String?, payload: T) async -> Bool {
        guard let serverURL = ABSClientProvider.serverURL else { return false }
        let update: Components.Schemas.mediaProgressUpdate
        do {
            let data = try JSONEncoder().encode(payload)
            update = try JSONDecoder().decode(Components.Schemas.mediaProgressUpdate.self, from: data)
        } catch {
            AbsLogger.error(message: "ABSApi.updateMediaProgress: failed to build update DTO: \(error)")
            return false
        }
        return await ABSApiClient.updateMediaProgress(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            update: update
        )
    }

    /// POST /api/session/{sessionId}/sync — progress heartbeat for an open server session.
    static func reportPlaybackProgress(report: PlaybackReport, sessionId: String) async -> Bool {
        guard let serverURL = ABSClientProvider.serverURL else { return false }
        let dto = Components.Schemas.playbackReport(
            currentTime: report.currentTime,
            duration: report.duration,
            timeListened: report.timeListened
        )
        return await ABSApiClient.syncPlaybackSession(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            sessionId: sessionId,
            report: dto
        )
    }

    /// POST /api/session/local — sync a single locally-recorded session. `session` must be frozen.
    static func reportLocalPlaybackProgress(_ session: PlaybackSession) async -> Bool {
        guard let serverURL = ABSClientProvider.serverURL else { return false }
        return await ABSApiClient.syncLocalPlaybackSession(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            session: session.toDTO()
        )
    }

    /// POST /api/session/local-all — bulk-sync offline sessions. Sessions must be frozen.
    static func reportAllLocalPlaybackSessions(_ sessions: [PlaybackSession]) async -> Bool {
        guard let serverURL = ABSClientProvider.serverURL else { return false }
        let body = Components.Schemas.localPlaybackSessionSyncAll(
            sessions: sessions.map { $0.toDTO() },
            deviceInfo: PlaybackSession.deviceInfoDTO(from: sessions.first?.deviceInfo)
        )
        return await ABSApiClient.syncAllLocalPlaybackSessions(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            body: body
        )
    }

    /// POST /api/items/{id}/play[/{episodeId}] → Realm `PlaybackSession` (with server-connection
    /// fields set), or nil on failure.
    ///
    /// The generated play response models `libraryItem` as `libraryItemMinified` (no
    /// `audioFiles[].ino`), so the mapped session's `libraryItem` is left nil. That `ino` is only
    /// used by AudioPlayer.createAsset for directplay on servers < 2.22.0 and a local-file
    /// streaming fallback; on servers ≥ 2.22.0 directplay uses `/public/session/{id}/track/{index}`
    /// and transcode uses the track `contentUrl`, both fully covered by the mapped audioTracks.
    static func startPlaybackSession(libraryItemId: String, episodeId: String?, forceTranscode: Bool) async -> PlaybackSession? {
        guard let serverConfig = Store.serverConfig, let serverURL = URL(string: serverConfig.address) else {
            AbsLogger.error(message: "ABSApi.startPlaybackSession: no server configured")
            return nil
        }
        let request = Components.Schemas.playbackSessionRequest(
            forceDirectPlay: forceTranscode ? ._empty : ._1,
            forceTranscode: forceTranscode ? ._1 : ._empty,
            mediaPlayer: "AVPlayer",
            deviceInfo: Self.deviceInfoRequest()
        )
        guard let dto = await ABSApiClient.startPlaybackSession(
            serverURL: serverURL,
            accessToken: ABSClientProvider.accessToken,
            refresher: ABSClientProvider.refresher,
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            request: request
        ) else {
            AbsLogger.error(message: "ABSApi.startPlaybackSession: request failed")
            return nil
        }
        let session = PlaybackSession.from(dto: dto)
        // Attach the active server connection, exactly as the legacy ApiClient did.
        session.serverConnectionConfigId = serverConfig.id
        session.serverAddress = serverConfig.address
        return session
    }

    /// Build the deviceInfoRequest the client sends when starting a session (the server enriches
    /// the rest). Mirrors the DeviceInfo the legacy ApiClient.startPlaybackSession sent.
    private static func deviceInfoRequest() -> Components.Schemas.deviceInfoRequest {
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }
        return Components.Schemas.deviceInfoRequest(
            deviceId: UIDevice.current.identifierForVendor?.uuidString,
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            manufacturer: "Apple",
            model: modelCode
        )
    }
}
