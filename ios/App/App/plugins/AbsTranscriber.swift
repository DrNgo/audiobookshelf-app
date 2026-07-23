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
        CAPPluginMethod(name: "disable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "buildContext", returnType: CAPPluginReturnPromise)
    ]

    // Isolated to the main actor: these three are read/written from Task closures
    // that run off the caller's thread, so all access is hopped onto @MainActor to
    // serialize the session-token check against the scheduler assignment. Capacitor
    // already invokes the @objc methods on the main thread.
    @MainActor private var scheduler: CaptionScheduler?
    @MainActor private var lastReportedTime: Double = 0
    // Session generation. Bumped by every enable()/disable(); an in-flight enable
    // Task captures the value at start and bails at each checkpoint if it no longer
    // matches, so a superseded enable can never resurrect or overwrite a scheduler.
    @MainActor private var enableGeneration = 0

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
        Task { @MainActor in await self.scheduler?.suspend() }
    }

    @objc private func appWillEnterForeground() {
        Task { @MainActor in await self.scheduler?.resume() }
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
            // Resolve to the supported EQUIVALENT (en-CA → en-US, etc.); nil means
            // the language genuinely isn't supported.
            let resolved = await SpeechTranscriptionEngine.supportedEquivalent(of: Locale.current)
            let available = resolved != nil
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

        Task { @MainActor in
            // Session token: supersede any earlier in-flight enable (still awaiting
            // model download etc.) so it bails at its next checkpoint instead of
            // resurrecting a stale scheduler. All shared-state access below runs on
            // the main actor, so the token check and the scheduler assignment are
            // serialized against a racing disable()/enable().
            self.enableGeneration += 1
            let gen = self.enableGeneration
            self.lastReportedTime = currentTime

            // Idempotent: tear down any scheduler from a prior enable before starting
            // a new one, so a rapid re-enable / book-change can't leak a running
            // scheduler or double-run the engine.
            await self.scheduler?.stop()
            self.scheduler = nil
            guard gen == self.enableGeneration else { call.resolve(); return }

            // Resolve the device locale to its supported EQUIVALENT once, and thread
            // THAT through model install + engine + store so the installed model
            // matches the one used (en-CA → en-US, etc.).
            guard let resolved = await SpeechTranscriptionEngine.supportedEquivalent(of: Locale.current) else {
                guard gen == self.enableGeneration else { call.resolve(); return }
                self.notifyStatus("error", "This language is not supported")
                call.reject("This language is not supported")
                return
            }
            guard gen == self.enableGeneration else { call.resolve(); return }

            do {
                try await self.requestAuthorization()
            } catch {
                guard gen == self.enableGeneration else { call.resolve(); return }
                self.notifyStatus("error", "Speech recognition permission was denied")
                call.reject("Speech recognition permission was denied")
                return
            }
            guard gen == self.enableGeneration else { call.resolve(); return }

            // Only surface "downloading language support" when a download will
            // actually happen; prepareModel is a fast no-op when installed.
            let alreadyInstalled = await SpeechTranscriptionEngine.isModelInstalled(locale: resolved)
            guard gen == self.enableGeneration else { call.resolve(); return }
            if !alreadyInstalled {
                self.notifyStatus("downloading-model", nil)
            }
            do {
                try await SpeechTranscriptionEngine.prepareModel(locale: resolved)
            } catch {
                guard gen == self.enableGeneration else { call.resolve(); return }
                self.notifyStatus("error", "Could not download language support")
                call.reject("Could not download language support")
                return
            }
            guard gen == self.enableGeneration else { call.resolve(); return }

            guard let context = self.buildContext(libraryItemId: libraryItemId) else {
                guard gen == self.enableGeneration else { call.resolve(); return }
                self.notifyStatus("error", "This book is not downloaded")
                call.reject("This book is not downloaded")
                return
            }
            // buildContext does not await; re-check before building/publishing.
            guard gen == self.enableGeneration else { call.resolve(); return }

            self.notifyStatus("preparing", nil)

            // Load the biasing vocabulary built at download time (empty if none).
            let contextTerms = CaptionContextStore(directory: context.directory).load()
            let engine = SpeechTranscriptionEngine(locale: resolved, contextualStrings: contextTerms)
            let scheduler = CaptionScheduler(
                tracks: context.tracks,
                fileURLs: context.fileURLs,
                store: CaptionStore(directory: context.directory),
                engine: engine,
                locale: resolved.identifier(.bcp47),
                onSegments: { [weak self] segments in
                    self?.notifySegments(segments)
                }
            )
            // Superseded while constructing the scheduler? Tear down what we built
            // rather than publishing/starting it.
            guard gen == self.enableGeneration else {
                await scheduler.stop()
                call.resolve()
                return
            }
            self.scheduler = scheduler
            await scheduler.start(at: currentTime)
            // A disable()/enable() may have landed during start(): if so, stop the
            // scheduler and only clear the slot if it's still ours.
            guard gen == self.enableGeneration else {
                await scheduler.stop()
                if self.scheduler === scheduler { self.scheduler = nil }
                call.resolve()
                return
            }
            self.notifyStatus("ready", nil)
            call.resolve()
        }
    }

    /// Called on every player time report. Small deltas keep the window topped
    /// up as playback progresses; a large jump is a seek and discards in-flight
    /// work for the region the listener just left.
    @objc func updateTime(_ call: CAPPluginCall) {
        let currentTime = call.getDouble("currentTime") ?? 0

        Task { @MainActor in
            let isSeek = abs(currentTime - self.lastReportedTime) > 5
            self.lastReportedTime = currentTime
            if isSeek {
                await self.scheduler?.seek(to: currentTime)
            } else {
                await self.scheduler?.advance(to: currentTime)
            }
            call.resolve()
        }
    }

    @objc func disable(_ call: CAPPluginCall) {
        Task { @MainActor in
            // Supersede any in-flight enable Task so it can't publish a scheduler
            // after we've torn down.
            self.enableGeneration += 1
            await self.scheduler?.stop()
            self.scheduler = nil
            call.resolve()
        }
    }

    // MARK: - Context (biasing vocabulary)

    /// The download folder for a library item id (server or local id), or nil
    /// if the item isn't a downloaded book.
    private func downloadDirectory(for libraryItemId: String) -> URL? {
        let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: libraryItemId)
            ?? Database.shared.getLocalLibraryItem(localLibraryItemId: libraryItemId)
        guard let item = item, item.isBook else { return nil }
        return item.contentDirectory
    }

    @objc func buildContext(_ call: CAPPluginCall) {
        guard let libraryItemId = call.getString("libraryItemId") else {
            call.reject("libraryItemId is required")
            return
        }
        let fields = call.getArray("fields", String.self) ?? []
        let bookBlurb = call.getString("bookBlurb") ?? ""
        let seriesBlurbs = call.getArray("seriesBlurbs", String.self) ?? []

        // Off the main thread — NER over several blurbs is CPU work.
        DispatchQueue.global(qos: .utility).async {
            guard let directory = self.downloadDirectory(for: libraryItemId) else {
                // Not a downloaded book (or gone) — nothing to store; not an error.
                call.resolve(["termCount": 0])
                return
            }
            let terms = CaptionContextBuilder.build(fields: fields, bookBlurb: bookBlurb, seriesBlurbs: seriesBlurbs)
            do {
                try CaptionContextStore(directory: directory).save(terms)
            } catch {
                AppLogger(category: "AbsTranscriber").error("Failed to write caption context: \(error)")
                call.resolve(["termCount": 0])
                return
            }
            call.resolve(["termCount": terms.count])
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
