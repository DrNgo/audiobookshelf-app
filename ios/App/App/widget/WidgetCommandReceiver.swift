//
//  WidgetCommandReceiver.swift
//  App
//
//  Observes the Darwin notification the widget posts for a transport command and runs it on the
//  player. App-only (touches PlayerHandler / Realm). Registered once at launch. Works while the app
//  is alive (which it is during playback); a play command with no active session resumes the most
//  recent in-progress book.
//

import Foundation

final class WidgetCommandReceiver {
    static let shared = WidgetCommandReceiver()

    func start() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in WidgetCommandReceiver.shared.handlePending() },
            WidgetPlaybackCommand.darwinNotification,
            nil,
            .deliverImmediately)
    }

    private func handlePending() {
        guard let command = WidgetPlaybackCommand.takePending() else { return }
        DispatchQueue.main.async {
            switch command {
            case .playPause:
                if PlayerHandler.getPlaybackSession() != nil {
                    PlayerHandler.paused.toggle()
                } else {
                    Task { @MainActor in
                        if let item = (await BrowseApi.continueListening()).first {
                            BrowsePlaybackStarter.play(item) {}
                        }
                    }
                }
            case .skipForward:
                PlayerHandler.seekForward(amount: Double(Database.shared.getDeviceSettings().jumpForwardTime))
            case .skipBackward:
                PlayerHandler.seekBackward(amount: Double(Database.shared.getDeviceSettings().jumpBackwardsTime))
            }
        }
    }
}
