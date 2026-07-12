//
//  WidgetDeepLink.swift
//  App
//
//  Handles the widget's tap-to-resume deep link (audiobookshelf://resume). The resume is DEFERRED
//  to applicationDidBecomeActive: on a cold launch the URL arrives while Realm/Store/the player are
//  still initializing, and resuming that early builds a degenerate session (position 0, no tracks)
//  that then fails to play. Running it once the app is active resumes from the saved position.
//

import Foundation
import UIKit

enum WidgetDeepLink {
    private static var resumePending = false

    /// True if `url` is the widget resume link. Marks the resume pending (performed on next active).
    @discardableResult
    static func noteIfResume(_ url: URL) -> Bool {
        guard url.scheme == "audiobookshelf", url.host == "resume" else { return false }
        resumePending = true
        return true
    }

    /// Run a pending resume, if any. Call once the app is active (Realm/Store/player are ready).
    static func performPendingResume() {
        guard resumePending else { return }
        resumePending = false
        Task { @MainActor in
            // Already loaded (e.g. suspended-with-session): just resume in place, don't restart.
            if PlayerHandler.getPlaybackSession() != nil {
                PlayerHandler.paused = false
            } else if let item = (await BrowseApi.continueListening()).first {
                BrowsePlaybackStarter.play(item) {}
            }
        }
    }
}
