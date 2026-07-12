//
//  WidgetPlaybackCommand.swift
//  App + AudiobookshelfWidget
//
//  Transport commands the widget's control buttons send to the app. A widget extension can't touch
//  the player directly, so the button intent writes the command to the shared App Group and posts a
//  Darwin notification; the app (alive during playback) observes it and runs it on PlayerHandler.
//  Deliberately free of app-only types so it compiles in BOTH the app and widget targets.
//

import Foundation
import AppIntents

enum WidgetPlaybackCommand: String {
    case playPause
    case skipForward
    case skipBackward

    static let darwinNotification = "com.audiobookshelf.widget.command" as CFString
    private static let pendingKey = "widget.pendingCommand"

    /// Widget side: record the command and wake the app.
    func send() {
        UserDefaults(suiteName: WidgetSharedCredentials.appGroup)?.set(rawValue, forKey: Self.pendingKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotification), nil, nil, true)
    }

    /// App side: read and clear the pending command.
    static func takePending() -> WidgetPlaybackCommand? {
        let defaults = UserDefaults(suiteName: WidgetSharedCredentials.appGroup)
        guard let raw = defaults?.string(forKey: pendingKey) else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        return WidgetPlaybackCommand(rawValue: raw)
    }
}

// MARK: - Button intents (iOS 17+ interactive widgets)

@available(iOS 17.0, *)
struct WidgetPlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var isDiscoverable: Bool { false } // widget-internal, not a Shortcuts action
    func perform() async throws -> some IntentResult { WidgetPlaybackCommand.playPause.send(); return .result() }
}

@available(iOS 17.0, *)
struct WidgetSkipForwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var isDiscoverable: Bool { false }
    func perform() async throws -> some IntentResult { WidgetPlaybackCommand.skipForward.send(); return .result() }
}

@available(iOS 17.0, *)
struct WidgetSkipBackwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Back"
    static var isDiscoverable: Bool { false }
    func perform() async throws -> some IntentResult { WidgetPlaybackCommand.skipBackward.send(); return .result() }
}
