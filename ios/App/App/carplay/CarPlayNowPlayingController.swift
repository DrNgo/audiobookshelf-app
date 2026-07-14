//
//  CarPlayNowPlayingController.swift
//  App
//
//  Adds a "Chapters" affordance to the CarPlay Now Playing screen by repurposing the built-in
//  Up Next button. Tapping it pushes a list of the current book's chapters; selecting a chapter
//  seeks playback to that chapter's start and returns to Now Playing. The button is enabled only
//  while the current book actually has chapters.
//
//  Threading: every entry point runs on the main thread — the CarPlay observer callback is
//  main-thread, and the player-event observers are registered on the main queue — so it is safe to
//  touch the main-thread-only CPNowPlayingTemplate and to read the main-thread Realm session here.
//  PlaybackSession is a thread-confined Realm object, so chapters are flattened to value types on
//  this thread before any are captured by a deferred tap handler.
//

import CarPlay
import UIKit

final class CarPlayNowPlayingController: NSObject, CPNowPlayingTemplateObserver {
    private weak var interfaceController: CPInterfaceController?
    private let template = CPNowPlayingTemplate.shared
    private var observers: [NSObjectProtocol] = []
    /// The session id the Chapters button was last synced for; avoids re-querying Realm every
    /// PlayerEvents.update tick (which fires ~1/sec while playing).
    private var lastSyncedSessionId: String?

    /// A chapter flattened to value types so tap handlers never capture a thread-confined Realm object.
    private struct ChapterEntry { let title: String; let start: Double; let end: Double }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
        template.upNextTitle = "Chapters"
        template.add(self)
        // Player events can post off the main thread, so observe on the main queue: the callback
        // touches the main-thread-only template.
        for event in [PlayerEvents.update, PlayerEvents.closed] {
            let observer = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(event.rawValue), object: nil, queue: .main
            ) { [weak self] _ in self?.syncChaptersButton() }
            observers.append(observer)
        }
        syncChaptersButton()
    }

    deinit {
        stop()
    }

    /// Detach from the shared Now Playing template and NotificationCenter. Must be called explicitly
    /// on CarPlay disconnect: CPNowPlayingTemplate.shared is a singleton that retains its observers,
    /// so without this the controller (and its observers) would outlive the scene and pile up across
    /// reconnects. Idempotent — safe to call from both `stop()` and `deinit`.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        template.remove(self)
    }

    /// Enable the "Chapters" (Up Next) button only when the current book has more than one chapter.
    private func syncChaptersButton() {
        // getPlaybackSessionId() is a plain in-memory String (no Realm); only open the Realm session
        // to recount chapters when the id actually changes (PlayerEvents.update fires ~1/sec).
        let sessionId = PlayerHandler.getPlaybackSessionId()
        if sessionId == lastSyncedSessionId { return }
        lastSyncedSessionId = sessionId
        template.isUpNextButtonEnabled = (PlayerHandler.getPlaybackSession()?.chapters.count ?? 0) > 1
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        presentChapters()
    }

    // MARK: - Chapters list

    private func presentChapters() {
        guard let session = PlayerHandler.getPlaybackSession() else { return }
        // Flatten to value types up front (on this main thread) so nothing Realm-confined escapes
        // into the deferred row handlers.
        let entries: [ChapterEntry] = session.chapters.enumerated().map { index, chapter in
            ChapterEntry(title: chapter.title ?? "Chapter \(index + 1)", start: chapter.start, end: chapter.end)
        }
        guard !entries.isEmpty else { return }
        let currentTime = PlayerHandler.getCurrentTime() ?? session.currentTime

        let capped = Array(entries.prefix(CPListTemplate.maximumItemCount))
        if capped.count < entries.count {
            AbsLogger.error(message: "CarPlay: chapter list truncated to \(capped.count)/\(entries.count) (maximumItemCount)")
        }
        let items: [CPListItem] = capped.map { entry in
            let isCurrent = currentTime >= entry.start && currentTime < entry.end
            return CarPlayRow.selectable(text: entry.title, detailText: Self.formatTimestamp(entry.start),
                                         isActive: isCurrent) { [weak self] in
                PlayerHandler.seek(amount: entry.start)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        }
        let list = CPListTemplate(title: "Chapters", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true) { ok, error in
            if !ok { AbsLogger.error(message: "CarPlay: pushTemplate(chapters) failed: \(String(describing: error))") }
        }
    }

    /// Format a chapter start time as H:MM:SS (or M:SS under an hour) for the row's detail text.
    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }
}
