//
//  WidgetSharedCredentials.swift
//  App + AudiobookshelfWidget
//
//  The small credential set the widget needs to call the server, stored in the shared App Group.
//  Deliberately pure Foundation (no app-only types) so the same file compiles in BOTH the app and
//  the widget-extension target. The app writes; the widget reads.
//

import Foundation

enum WidgetSharedCredentials {
    static let appGroup = "group.com.audiobookshelf.app"
    private static let serverURLKey = "widget.serverURL"
    private static let tokenKey = "widget.accessToken"

    static func save(serverURL: String, token: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(serverURL, forKey: serverURLKey)
        defaults?.set(token, forKey: tokenKey)
    }

    static func load() -> (serverURL: URL, token: String)? {
        let defaults = UserDefaults(suiteName: appGroup)
        guard let address = defaults?.string(forKey: serverURLKey), let url = URL(string: address),
              let token = defaults?.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return (url, token)
    }

    // Live play/pause state, so the widget's play/pause button can show the right glyph.
    private static let isPlayingKey = "widget.isPlaying"
    static var isPlaying: Bool { UserDefaults(suiteName: appGroup)?.bool(forKey: isPlayingKey) ?? false }
    static func setIsPlaying(_ playing: Bool) { UserDefaults(suiteName: appGroup)?.set(playing, forKey: isPlayingKey) }
}
