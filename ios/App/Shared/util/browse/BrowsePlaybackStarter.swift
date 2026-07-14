//
//  BrowsePlaybackStarter.swift
//  App
//
//  Starts playback for a row selected outside the WebView (CarPlay, Siri App Intents) by handing the
//  request to the app's mature web play flow — the SAME `audiobookshelf://resume` deep link the widget
//  uses — rather than starting a native AudioPlayer here.
//
//  Why web-driven: the phone's web player and a natively-started player share one native AudioPlayer,
//  so starting playback natively here let the two fight over play/pause (the web layer would send a
//  `playPause` that paused the CarPlay-initiated session). Routing through the web keeps a single
//  source of truth: `AudioPlayerContainer.onUrlOpen` resolves local-vs-server by the id prefix and
//  starts via `playLibraryItem` → `prepareLibraryItem`, which also drives Now Playing correctly.
//

import Foundation
import UIKit
import Capacitor

enum BrowsePlaybackStarter {
    /// Begin playback for the selected row via the web layer. `onStarted` runs immediately after the
    /// deep link is dispatched (the caller uses it to present the CarPlay Now Playing template); it is
    /// not a completion signal that audio is playing. Must be invoked on the main thread.
    @MainActor
    static func play(_ item: BrowseItem, onStarted: @escaping () -> Void) {
        var components = URLComponents()
        components.scheme = "audiobookshelf"
        components.host = "resume"
        // The web handler resolves local (downloaded) vs server by the id prefix ("local..."), so the
        // same link works for both. Books only in the browse slice, so no episodeId.
        components.queryItems = [URLQueryItem(name: "libraryItemId", value: item.id)]

        guard let url = components.url else {
            AbsLogger.error(message: "BrowsePlaybackStarter: failed to build resume URL for \(item.id)")
            return
        }

        // Forward through Capacitor's proxy so the web layer receives it via appUrlOpen — exactly how
        // the widget's cold/warm resume reaches AudioPlayerContainer.onUrlOpen.
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: url, options: [:])
        onStarted()
    }
}
