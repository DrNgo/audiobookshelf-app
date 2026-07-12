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
    ///
    /// Only resumes a session that is ALREADY loaded (e.g. app was alive/paused) — it just unpauses
    /// in place. On a cold launch there is no session, and starting one natively here fought the
    /// app's init + the WebView's own state restoration (degenerate 0/0 session, playback errors), so
    /// we deliberately do NOT native-start on cold launch: the app is already opening, and the user
    /// resumes through the mature in-app flow (or we hand the resume to the web layer — see handoff).
    static func performPendingResume() {
        guard resumePending else { return }
        resumePending = false
        Task { @MainActor in
            if PlayerHandler.getPlaybackSession() != nil {
                PlayerHandler.paused = false
            }
        }
    }
}
