//
//  CarPlayNowPlayingController.swift
//  App
//
//  Adds book-oriented controls to the CarPlay Now Playing screen:
//   - A "Chapters" affordance on the built-in Up Next button: tapping it pushes a list of the current
//     book's chapters; selecting one seeks to its start and returns to Now Playing.
//   - A control-row speed button that pushes a playback-speed picker (checkmark on the current speed).
//   - Control-row previous/next-chapter buttons (shown only when the book has chapters).
//  All are enabled/shown only while the current book actually has chapters (except speed, always shown).
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
            ) { [weak self] _ in self?.syncButtons() }
            observers.append(observer)
        }
        syncButtons()
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

    /// Sync the chapter-dependent controls (Up Next "Chapters" button + control-row buttons) with the
    /// current book. The speed button is always present; the previous/next-chapter buttons appear only
    /// when the book has chapters.
    private func syncButtons() {
        // getPlaybackSessionId() is a plain in-memory String (no Realm); only rebuild the controls
        // when the session actually changes (PlayerEvents.update fires ~1/sec).
        let sessionId = PlayerHandler.getPlaybackSessionId()
        if sessionId == lastSyncedSessionId { return }
        lastSyncedSessionId = sessionId

        let hasChapters = (PlayerHandler.getPlaybackSession()?.chapters.count ?? 0) > 1
        template.isUpNextButtonEnabled = hasChapters

        let speedButton = CPNowPlayingImageButton(image: Self.symbol("speedometer")) { [weak self] _ in
            self?.presentSpeedPicker()
        }
        if hasChapters {
            let prev = CPNowPlayingImageButton(image: Self.symbol("backward.end")) { [weak self] _ in
                self?.seekChapter(-1)
            }
            let next = CPNowPlayingImageButton(image: Self.symbol("forward.end")) { [weak self] _ in
                self?.seekChapter(1)
            }
            template.updateNowPlayingButtons([prev, speedButton, next])
        } else {
            template.updateNowPlayingButtons([speedButton])
        }
    }

    private static func symbol(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
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

    // MARK: - Speed picker

    /// The playback speeds offered, matching the phone app's speed modal.
    private static let speeds: [Float] = [0.5, 1, 1.2, 1.5, 1.7, 2, 3]

    private func presentSpeedPicker() {
        let current = PlayerHandler.getPlaybackSpeed()
        let items: [CPListItem] = Self.speeds.map { speed in
            CarPlayRow.selectable(text: Self.formatSpeed(speed),
                                  isActive: current.map { abs($0 - speed) < 0.001 } ?? false) { [weak self] in
                PlayerHandler.setPlaybackSpeed(speed: speed)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        }
        let list = CPListTemplate(title: "Speed", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true) { ok, error in
            if !ok { AbsLogger.error(message: "CarPlay: pushTemplate(speed) failed: \(String(describing: error))") }
        }
    }

    /// "1×", "1.2×", etc. — whole speeds drop the decimal.
    private static func formatSpeed(_ speed: Float) -> String {
        let text = speed.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", speed)
                                                                  : String(format: "%.1f", speed)
        return "\(text)×"
    }

    // MARK: - Chapter navigation

    /// Seek to the previous (delta -1) or next (delta +1) chapter. "Previous" from more than 3s into a
    /// chapter restarts the current chapter first, matching common transport behavior.
    private func seekChapter(_ delta: Int) {
        guard let session = PlayerHandler.getPlaybackSession() else { return }
        let starts = session.chapters.map { $0.start }   // value types; nothing Realm-confined escapes
        guard !starts.isEmpty else { return }
        let currentTime = PlayerHandler.getCurrentTime() ?? session.currentTime
        let index = starts.lastIndex(where: { $0 <= currentTime }) ?? 0
        var target = index + delta
        if delta < 0 && currentTime - starts[index] > 3 { target = index }
        target = max(0, min(target, starts.count - 1))
        PlayerHandler.seek(amount: starts[target])
    }

    /// Format a chapter start time as H:MM:SS (or M:SS under an hour) for the row's detail text.
    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }
}
