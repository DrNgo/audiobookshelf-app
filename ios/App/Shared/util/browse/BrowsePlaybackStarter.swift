//
//  BrowsePlaybackStarter.swift
//  App
//
//  Starts native playback for a CarPlay row, reusing the exact paths the phone player uses
//  (local session build / server startPlaybackSession). It drives PlayerHandler directly; the
//  system Now Playing screen is populated by the existing AudioPlayer + NowPlayingInfo, so no
//  CarPlay-specific transport code is needed.
//

import Foundation

enum BrowsePlaybackStarter {
    /// Begin playback for the selected row. `onStarted` runs on the main thread once the session
    /// is playing (the caller uses it to present the Now Playing template); it is not called on
    /// failure. Must be invoked on the main thread — CarPlay row handlers already are.
    @MainActor
    static func play(_ item: BrowseItem, onStarted: @escaping () -> Void) {
        PlayerHandler.stopPlayback()
        let rate = PlayerSettings.main().playbackRate

        if item.isLocal {
            guard let local = Database.shared.getLocalLibraryItem(localLibraryItemId: item.id) else {
                AbsLogger.error(message: "CarPlay: no local item for \(item.id)")
                return
            }
            let session = local.getPlaybackSession(episode: nil)
            do {
                try session.save()
                PlayerHandler.startPlayback(sessionId: session.id, playWhenReady: true, playbackRate: rate)
                onStarted()
            } catch {
                AbsLogger.error(message: "CarPlay: failed to start local session: \(error)")
            }
        } else {
            // Callback is delivered on the main actor by ApiClient.startPlaybackSession.
            ApiClient.startPlaybackSession(libraryItemId: item.id, episodeId: nil, forceTranscode: false) { session in
                guard !session.id.isEmpty else {
                    AbsLogger.error(message: "CarPlay: empty session for \(item.id)")
                    return
                }
                do {
                    try session.save()
                    PlayerHandler.startPlayback(sessionId: session.id, playWhenReady: true, playbackRate: rate)
                    onStarted()
                } catch {
                    AbsLogger.error(message: "CarPlay: failed to start server session: \(error)")
                }
            }
        }
    }
}
