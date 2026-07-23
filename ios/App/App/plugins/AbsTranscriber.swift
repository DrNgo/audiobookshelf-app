//
//  AbsTranscriber.swift
//  App
//
//  Capacitor surface for read-while-listening captions. This is the ONLY file
//  permitted to contain an iOS 26 availability check — everything below it is
//  version-agnostic.
//

import Foundation
import UIKit
import Capacitor
import Speech
import RealmSwift

@objc(AbsTranscriber)
public class AbsTranscriber: CAPPlugin, CAPBridgedPlugin {
    public var identifier = "AbsTranscriberPlugin"
    public var jsName = "AbsTranscriber"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateTime", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disable", returnType: CAPPluginReturnPromise)
    ]

    private var scheduler: CaptionScheduler?
    private var lastReportedTime: Double = 0

    // MARK: - Background handling

    override public func load() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        Task { await self.scheduler?.suspend() }
    }

    @objc private func appWillEnterForeground() {
        Task { await self.scheduler?.resume() }
    }

    // MARK: - Capability

    @objc func isSupported(_ call: CAPPluginCall) {
        guard #available(iOS 26.0, *) else {
            call.resolve(["supported": false, "reason": "os"])
            return
        }
        Task {
            let status = SFSpeechRecognizer.authorizationStatus()
            guard status == .authorized || status == .notDetermined else {
                call.resolve(["supported": false, "reason": "permission"])
                return
            }
            let available = await SpeechTranscriptionEngine.isAvailable(locale: Locale.current)
            call.resolve(["supported": available, "reason": available ? "ok" : "locale"])
        }
    }

    // MARK: - Lifecycle

    @objc func enable(_ call: CAPPluginCall) {
        guard #available(iOS 26.0, *) else {
            call.reject("Captions require iOS 26 or later")
            return
        }
        guard let libraryItemId = call.getString("libraryItemId") else {
            call.reject("libraryItemId is required")
            return
        }
        let currentTime = call.getDouble("currentTime") ?? 0
        lastReportedTime = currentTime

        Task {
            do {
                try await self.requestAuthorization()
            } catch {
                self.notifyStatus("error", "Speech recognition permission was denied")
                call.reject("Speech recognition permission was denied")
                return
            }

            self.notifyStatus("downloading-model", nil)
            do {
                try await SpeechTranscriptionEngine.prepareModel(locale: Locale.current)
            } catch {
                self.notifyStatus("error", "Could not download language support")
                call.reject("Could not download language support")
                return
            }

            guard let context = self.buildContext(libraryItemId: libraryItemId) else {
                self.notifyStatus("error", "This book is not downloaded")
                call.reject("This book is not downloaded")
                return
            }

            self.notifyStatus("preparing", nil)

            let engine = SpeechTranscriptionEngine(locale: Locale.current)
            let scheduler = CaptionScheduler(
                tracks: context.tracks,
                fileURLs: context.fileURLs,
                store: CaptionStore(directory: context.directory),
                engine: engine,
                locale: Locale.current.identifier(.bcp47),
                onSegments: { [weak self] segments in
                    self?.notifySegments(segments)
                }
            )
            self.scheduler = scheduler
            await scheduler.start(at: currentTime)
            self.notifyStatus("ready", nil)
            call.resolve()
        }
    }

    /// Called on every player time report. Small deltas keep the window topped
    /// up as playback progresses; a large jump is a seek and discards in-flight
    /// work for the region the listener just left.
    @objc func updateTime(_ call: CAPPluginCall) {
        let currentTime = call.getDouble("currentTime") ?? 0
        let isSeek = abs(currentTime - lastReportedTime) > 5
        lastReportedTime = currentTime

        Task {
            if isSeek {
                await self.scheduler?.seek(to: currentTime)
            } else {
                await self.scheduler?.advance(to: currentTime)
            }
            call.resolve()
        }
    }

    @objc func disable(_ call: CAPPluginCall) {
        Task {
            await self.scheduler?.stop()
            self.scheduler = nil
            call.resolve()
        }
    }

    // MARK: - Helpers

    private struct Context {
        let tracks: [CaptionTrack]
        let fileURLs: [String: URL]
        let directory: URL
    }

    /// Flatten the Realm item into the value types the scheduler understands.
    private func buildContext(libraryItemId: String) -> Context? {
        guard let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: libraryItemId)
                ?? Database.shared.getLocalLibraryItem(localLibraryItemId: libraryItemId),
              item.isBook,
              let media = item.media,
              let directory = item.contentDirectory
        else { return nil }

        var tracks: [CaptionTrack] = []
        var fileURLs: [String: URL] = [:]

        for (offset, track) in media.tracks.enumerated() {
            guard let localFileId = track.localFileId,
                  let localFile = item.localFiles.first(where: { $0.id == localFileId })
            else { continue }
            // AudioTrack.index and serverIndex are both Int? in the Realm model;
            // fall back to enumeration order so CaptionTrack.index is always set.
            let index = track.index ?? track.serverIndex ?? offset
            tracks.append(CaptionTrack(index: index,
                                       startOffset: track.startOffset ?? 0,
                                       duration: track.duration,
                                       localFileId: localFileId))
            fileURLs[localFileId] = localFile.contentPath
        }

        guard !tracks.isEmpty else { return nil }
        return Context(tracks: tracks, fileURLs: fileURLs, directory: directory)
    }

    private func requestAuthorization() async throws {
        struct Denied: Error {}
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Denied() }
    }

    private func notifySegments(_ segments: [CaptionSegment]) {
        let payload = segments.map { segment -> [String: Any] in
            [
                "start": segment.start,
                "end": segment.end,
                "text": segment.text,
                "words": segment.words.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
            ]
        }
        notifyListeners("onCaptionSegments", data: ["segments": payload])
    }

    private func notifyStatus(_ status: String, _ message: String?) {
        var data: [String: Any] = ["status": status]
        if let message { data["message"] = message }
        notifyListeners("onCaptionStatus", data: data)
    }
}
