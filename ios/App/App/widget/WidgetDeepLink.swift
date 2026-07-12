//
//  WidgetDeepLink.swift
//  App
//
//  Handles the widget's tap-to-resume deep link (audiobookshelf://resume) natively, before the URL
//  is forwarded to the Capacitor WebView.
//

import Foundation

enum WidgetDeepLink {
    /// If `url` is the widget resume link, start playback of the most-recent in-progress book and
    /// return true (handled). Otherwise return false so the caller forwards the URL onward.
    static func handleResume(_ url: URL) -> Bool {
        guard url.scheme == "audiobookshelf", url.host == "resume" else { return false }
        Task { @MainActor in
            if let item = (await BrowseApi.continueListening()).first {
                BrowsePlaybackStarter.play(item) {}
            }
        }
        return true
    }
}
