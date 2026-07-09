//
//  AbsDownloader.swift
//  App
//
//  Created by advplyr on 5/13/22.
//

import Foundation
import Capacitor
import RealmSwift

@objc(AbsDownloader)
public class AbsDownloader: CAPPlugin, CAPBridgedPlugin, URLSessionDownloadDelegate {
    public var identifier = "AbsDownloaderPlugin"
    public var jsName = "AbsDownloader"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "downloadLibraryItem", returnType: CAPPluginReturnPromise)
    ]
    
    static private let downloadsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "AbsDownloader")
        // Hardening: bound task lifetime and wait for connectivity instead of failing on a
        // transient blip. A background session's DEFAULT resource timeout is 7 DAYS, which is
        // why a silently stalled task could otherwise sit "downloading" forever.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 12 * 60 * 60 // 12h hard cap
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        // Serial delegate queue: guarantees a task's didFinishDownloadingTo (which commits
        // `completed = true`) fully finishes before its didCompleteWithError runs. With a concurrent
        // queue these could overlap on different threads, so the completion check could read the
        // part's own `completed` as still false and — with no polling fallback — wedge the item at
        // "Download complete. Processing...". Callbacks are lightweight; the only heavier step is a
        // same-volume file move, so serializing costs nothing meaningful.
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    // Stall detection + retry tuning
    private let stallTimeout: TimeInterval = 30     // no bytes for this long => treat as stalled
    private let stallCheckInterval: TimeInterval = 10
    private let maxRetriesPerPart = 3
    private var retryCounts: [String: Int] = [:]    // partId -> retries already used (guarded by downloadQueueLock)
    private var stalledPartIds: Set<String> = []    // parts we cancelled on purpose to retry (guarded by downloadQueueLock)
    private var finalizedItemIds: Set<String> = []  // items already finalized, so concurrent part completions finalize once (guarded by downloadQueueLock)
    private var stallWatchdogTimer: Timer?

    // Progress-write throttling (avoid a Realm write + bridge call on every byte callback)
    private let progressThrottleLock = NSLock()
    private var lastPersistAt: [String: Date] = [:]
    private let progressPersistInterval: TimeInterval = 1.0

    // Download queue management
    private let downloadQueueLock = NSLock()
    private var pendingDownloadTasks: [PendingDownload] = []
    private var activeDownloads: [String: ActiveDownload] = [:] // partId -> live state
    private let maxConcurrentDownloads = 3
    
    
    // MARK: - Download Queue Management

    private func startNextDownloadInQueue() {
        downloadQueueLock.lock()
        // Start downloads up to the max concurrent limit
        while activeDownloads.count < maxConcurrentDownloads && !pendingDownloadTasks.isEmpty {
            let next = pendingDownloadTasks.removeFirst()
            activeDownloads[next.partId] = ActiveDownload(partId: next.partId, filename: next.filename, downloadURL: next.downloadURL, task: next.task, lastBytesWritten: 0, lastProgressAt: Date())
            AbsLogger.info(message: "Starting download for \(next.filename) (\(activeDownloads.count)/\(maxConcurrentDownloads) active, \(pendingDownloadTasks.count) pending)")
            next.task.resume()
        }
        let hasActive = !activeDownloads.isEmpty
        downloadQueueLock.unlock()

        if hasActive { startStallWatchdogIfNeeded() }
    }

    private func enqueuePendingDownload(_ pending: PendingDownload) {
        downloadQueueLock.lock()
        pendingDownloadTasks.append(pending)
        downloadQueueLock.unlock()
    }

    // Reconnect to background downloads left over from a previous app launch so a relaunch can't
    // orphan an in-flight task (a background URLSession's tasks persist across process restarts).
    public override func load() {
        session.getAllTasks { tasks in
            var adoptedPartIds = Set<String>()
            self.downloadQueueLock.lock()
            var adopted = 0
            for task in tasks {
                guard let dl = task as? URLSessionDownloadTask, let partId = dl.taskDescription, let url = dl.originalRequest?.url else {
                    task.cancel()
                    continue
                }
                if self.activeDownloads[partId] == nil {
                    switch dl.state {
                    case .running, .suspended:
                        self.activeDownloads[partId] = ActiveDownload(partId: partId, filename: partId, downloadURL: url, task: dl, lastBytesWritten: 0, lastProgressAt: Date())
                        if dl.state == .suspended { dl.resume() }
                        adopted += 1
                        adoptedPartIds.insert(partId)
                    default:
                        break
                    }
                } else {
                    adoptedPartIds.insert(partId)
                }
            }
            self.downloadQueueLock.unlock()
            if adopted > 0 {
                AbsLogger.info(message: "Reconciled \(adopted) in-flight download task(s) from a previous session")
                self.startStallWatchdogIfNeeded()
            }

            // Live background tasks are only half the picture: the JS store learns about a download
            // solely via onDownloadItem at start time, so any DownloadItem persisted in the DB whose
            // tasks didn't survive the relaunch would be orphaned (never finishes, never clears).
            // Re-emit those to JS, restart their orphaned/failed parts, and finalize any that already
            // finished on disk. Runs on the session's (serial) delegate queue, so it can't race the
            // download callbacks.
            self.reconcilePersistedDownloads(adoptedPartIds: adoptedPartIds)
        }
    }

    private func reconcilePersistedDownloads(adoptedPartIds: Set<String>) {
        let realm: Realm
        do { realm = try Realm() } catch { return }
        realm.refresh()
        let items = Array(realm.objects(DownloadItem.self))
        guard !items.isEmpty else { return }

        var restartTasks: [PendingDownload] = []
        var partIdsToFinalize: [String] = []

        for item in items {
            var allDone = true
            var itemRestarts: [PendingDownload] = []
            for part in item.downloadItemParts {
                if part.completed && !part.failed { continue } // genuinely finished
                allDone = false
                if adoptedPartIds.contains(part.id) { continue } // still downloading via an adopted task
                guard let url = part.downloadURL else { continue }
                // Orphaned or previously-failed part: reset and re-download from scratch.
                try? realm.write {
                    part.progress = 0
                    part.bytesDownloaded = 0
                    part.failed = false
                    part.completed = false
                }
                let task = self.session.downloadTask(with: url)
                task.taskDescription = part.id
                itemRestarts.append(PendingDownload(partId: part.id, filename: part.filename ?? part.id, downloadURL: url, task: task))
            }

            // Everything already on disk but never finalized (app died mid-finalization). If a local
            // library item already exists it was finalized before the crash — just drop the stale
            // record; otherwise finalize it now.
            if allDone, Database.shared.getLocalLibraryItem(byServerLibraryItemId: item.libraryItemId ?? item.id ?? "") != nil {
                try? realm.write {
                    realm.delete(item.downloadItemParts)
                    realm.delete(item)
                }
                continue
            }

            // Genuine in-flight download — re-add it to the JS store.
            try? self.notifyListeners("onDownloadItem", data: item.asDictionary())
            restartTasks.append(contentsOf: itemRestarts)
            if allDone, let firstPartId = item.downloadItemParts.first?.id {
                partIdsToFinalize.append(firstPartId)
            }
        }

        for partId in partIdsToFinalize {
            checkItemCompletion(forPartId: partId)
        }

        if !restartTasks.isEmpty {
            downloadQueueLock.lock()
            pendingDownloadTasks.append(contentsOf: restartTasks)
            downloadQueueLock.unlock()
            AbsLogger.info(message: "Reconciled \(restartTasks.count) orphaned download part(s) from a previous session")
            startNextDownloadInQueue()
        }
    }

    private func isRecoverableError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }


    // MARK: - Progress handling

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        handleDownloadTaskUpdate(downloadTask: downloadTask) { downloadItem, downloadItemPart in
            let realm = try Realm()
            let partId = downloadItemPart.id

            // Get fresh reference to the object in this realm
            guard let liveDownloadItemPart = realm.object(ofType: DownloadItemPart.self, forPrimaryKey: partId) else {
                throw LibraryItemDownloadError.downloadItemPartNotFound
            }

            try realm.write {
                liveDownloadItemPart.bytesDownloaded = liveDownloadItemPart.fileSize
                liveDownloadItemPart.progress = 100
                liveDownloadItemPart.completed = true
            }
            
            do {
                // Move the downloaded file into place
                guard let destinationUrl = liveDownloadItemPart.destinationURL else {
                    throw LibraryItemDownloadError.downloadItemPartDestinationUrlNotDefined
                }
                try? FileManager.default.removeItem(at: destinationUrl)
                try FileManager.default.moveItem(at: location, to: destinationUrl)
                try realm.write {
                    liveDownloadItemPart.moved = true
                }
            } catch {
                try realm.write {
                    liveDownloadItemPart.failed = true
                }
                throw error
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let partId = task.taskDescription else { return }

        // Atomically release the concurrency slot and read state, so a finished/failed/stalled
        // task can NEVER permanently occupy a slot and jam the queue.
        downloadQueueLock.lock()
        let active = activeDownloads.removeValue(forKey: partId)
        let intentionalStallCancel = stalledPartIds.remove(partId) != nil
        let retries = retryCounts[partId] ?? 0
        downloadQueueLock.unlock()
        progressThrottleLock.lock()
        lastPersistAt.removeValue(forKey: partId)
        progressThrottleLock.unlock()

        if let error = error as NSError? {
            let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let recoverable = intentionalStallCancel || isRecoverableError(error)

            if recoverable && retries < maxRetriesPerPart {
                let url = active?.downloadURL ?? task.originalRequest?.url
                let retryTask: URLSessionDownloadTask? = {
                    if let resumeData = resumeData { return session.downloadTask(withResumeData: resumeData) }
                    if let url = url { return session.downloadTask(with: url) }
                    return nil
                }()
                if let retryTask = retryTask, let resolvedURL = url ?? retryTask.originalRequest?.url {
                    retryTask.taskDescription = partId
                    downloadQueueLock.lock()
                    retryCounts[partId] = retries + 1
                    downloadQueueLock.unlock()
                    AbsLogger.info(message: "Retrying \(active?.filename ?? partId) — attempt \(retries + 1)/\(maxRetriesPerPart) (resume=\(resumeData != nil), stalled=\(intentionalStallCancel))")
                    enqueuePendingDownload(PendingDownload(partId: partId, filename: active?.filename ?? partId, downloadURL: resolvedURL, task: retryTask))
                    startNextDownloadInQueue()
                    return
                }
            }

            // Out of retries or unrecoverable — mark failed and let the item resolve so the UI reverts
            AbsLogger.error(message: "Download failed for \(active?.filename ?? partId): \(error.localizedDescription)")
            clearRetryCount(partId)
            markPartFailed(partId)
            checkItemCompletion(forPartId: partId)
        } else {
            clearRetryCount(partId)
            checkItemCompletion(forPartId: partId)
        }

        startNextDownloadInQueue()
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let partId = downloadTask.taskDescription else { return }

        // Feed the stall watchdog on EVERY callback (not throttled) so it sees real forward progress
        downloadQueueLock.lock()
        if var dl = activeDownloads[partId] {
            dl.lastBytesWritten = totalBytesWritten
            dl.lastProgressAt = Date()
            activeDownloads[partId] = dl
        }
        downloadQueueLock.unlock()

        // Throttle the Realm write + JS bridge notify so we don't churn on every packet
        let isFinalChunk = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard shouldPersistProgress(partId: partId, isFinalChunk: isFinalChunk) else { return }

        handleDownloadTaskUpdate(downloadTask: downloadTask) { downloadItem, downloadItemPart in
            // Calculate the download percentage
            let percentDownloaded = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100

            // Only update the progress if we received accurate progress data
            if percentDownloaded >= 0.0 && percentDownloaded <= 100.0 {
                let realm = try Realm()
                let partId = downloadItemPart.id

                // Get fresh reference to the object in this realm
                guard let liveDownloadItemPart = realm.object(ofType: DownloadItemPart.self, forPrimaryKey: partId) else {
                    throw LibraryItemDownloadError.downloadItemPartNotFound
                }

                try realm.write {
                    liveDownloadItemPart.bytesDownloaded = Double(totalBytesWritten)
                    liveDownloadItemPart.progress = percentDownloaded
                }
            }
        }
    }
    
    // Called when downloads are complete on the background thread
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                let backgroundCompletionHandler =
                appDelegate.backgroundCompletionHandler else {
                    return
            }
            backgroundCompletionHandler()
        }
    }
    
    private func handleDownloadTaskUpdate(downloadTask: URLSessionTask, progressHandler: DownloadProgressHandler) {
        do {
            guard let downloadItemPartId = downloadTask.taskDescription else { throw LibraryItemDownloadError.noTaskDescription }

            // Find the download item
            let downloadItem = Database.shared.getDownloadItem(downloadItemPartId: downloadItemPartId)
            guard let downloadItem = downloadItem else { throw LibraryItemDownloadError.downloadItemNotFound }

            // Find the download item part
            let part = downloadItem.downloadItemParts.first(where: { $0.id == downloadItemPartId })
            guard let part = part else { throw LibraryItemDownloadError.downloadItemPartNotFound }

            // Call the progress handler and push the (throttled) update to the JS layer
            do {
                try progressHandler(downloadItem, part)
                try? self.notifyListeners("onDownloadItemPartUpdate", data: part.asDictionary())
            } catch {
                AbsLogger.error(message: "Error while processing progress")
                debugPrint(error)
            }
        } catch {
            AbsLogger.error(message: "DownloadItemError")
            debugPrint(error)
        }
    }

    private func shouldPersistProgress(partId: String, isFinalChunk: Bool) -> Bool {
        progressThrottleLock.lock()
        defer { progressThrottleLock.unlock() }
        let now = Date()
        let last = lastPersistAt[partId] ?? .distantPast
        if isFinalChunk || now.timeIntervalSince(last) >= progressPersistInterval {
            lastPersistAt[partId] = now
            return true
        }
        return false
    }

    private func clearRetryCount(_ partId: String) {
        downloadQueueLock.lock()
        retryCounts.removeValue(forKey: partId)
        downloadQueueLock.unlock()
    }

    // MARK: - Stall watchdog

    private func startStallWatchdogIfNeeded() {
        DispatchQueue.runOnMainQueue {
            guard self.stallWatchdogTimer?.isValid != true else { return }
            self.stallWatchdogTimer = Timer.scheduledTimer(withTimeInterval: self.stallCheckInterval, repeats: true, block: { [weak self] t in
                self?.checkForStalledDownloads(t)
            })
        }
    }

    private func checkForStalledDownloads(_ timer: Timer) {
        downloadQueueLock.lock()
        let now = Date()
        let stalled = activeDownloads.values.filter { now.timeIntervalSince($0.lastProgressAt) > stallTimeout }
        for dl in stalled { stalledPartIds.insert(dl.partId) }
        let idle = activeDownloads.isEmpty && pendingDownloadTasks.isEmpty
        downloadQueueLock.unlock()

        for dl in stalled {
            AbsLogger.error(message: "Stall detected on \(dl.filename): no data for >\(Int(stallTimeout))s — cancelling to retry")
            // Cancel producing resume data; this fires didCompleteWithError, which retries the part
            dl.task.cancel(byProducingResumeData: { _ in })
        }

        if idle && stalled.isEmpty {
            timer.invalidate()
            if self.stallWatchdogTimer == timer { self.stallWatchdogTimer = nil }
            AbsLogger.info(message: "No active downloads — stopping stall watchdog")
        }
    }

    // MARK: - Completion / failure

    private func markPartFailed(_ partId: String) {
        do {
            let realm = try Realm()
            guard let part = realm.object(ofType: DownloadItemPart.self, forPrimaryKey: partId) else { return }
            try realm.write {
                part.completed = true
                part.failed = true
            }
            try? self.notifyListeners("onDownloadItemPartUpdate", data: part.asDictionary())
        } catch {
            AbsLogger.error(message: "Failed to mark part failed \(partId)")
            debugPrint(error)
        }
    }

    // Event-driven completion (replaces the old 0.2s polling timer): when every part of an item
    // is done (completed or failed), assemble the local item and notify the JS layer once.
    private func checkItemCompletion(forPartId partId: String) {
        // The serial delegate queue can still run successive callbacks on different run-loop-less
        // threads, and a Realm opened on such a thread stays pinned to the snapshot it was first
        // opened at. So a sibling part's just-committed `completed = true` may be invisible here,
        // making isDoneDownloading() return false. Refresh to the latest committed version first —
        // otherwise, now that the old 0.2s polling loop is gone, this one-shot check never re-runs
        // and the item wedges forever at "Download complete. Processing...".
        _ = try? Realm().refresh()

        guard let item = Database.shared.getDownloadItem(downloadItemPartId: partId) else { return }
        guard item.isDoneDownloading() else { return }

        // Each part's completion calls this concurrently, so more than one can pass the check above.
        // Claim the item atomically so it finalizes exactly once (no duplicate local items / events).
        guard let itemId = item.id else { return }
        downloadQueueLock.lock()
        let alreadyFinalized = finalizedItemIds.contains(itemId)
        if !alreadyFinalized { finalizedItemIds.insert(itemId) }
        downloadQueueLock.unlock()
        guard !alreadyFinalized else { return }

        for p in item.downloadItemParts { clearRetryCount(p.id) }

        // Freeze so the item can be handed to the (main-queue) finalizer safely across threads.
        let frozen = item.freeze()
        handleDownloadTaskCompleteFromDownloadItem(frozen)

        if let live = Database.shared.getDownloadItem(downloadItemId: item.id!) {
            try? live.delete()
        }

        // Item is finalized and deleted; drop its claim so the set doesn't grow for the process
        // lifetime. Safe because the delegate queue is serial (no concurrent re-claim), and a later
        // duplicate call would early-return on the now-missing item anyway.
        downloadQueueLock.lock()
        finalizedItemIds.remove(itemId)
        downloadQueueLock.unlock()
    }
    
    private func handleDownloadTaskCompleteFromDownloadItem(_ downloadItem: DownloadItem) {
        AbsLogger.info(message: "Finalizing completed download \(downloadItem.itemTitle ?? downloadItem.id ?? "?")")
        var statusNotification = [String: Any]()
        statusNotification["libraryItemId"] = downloadItem.id

        guard downloadItem.didDownloadSuccessfully() else {
            // A part failed permanently — still notify so the UI reverts instead of hanging.
            self.notifyListeners("onItemDownloadComplete", data: statusNotification)
            return
        }

        // The files are already fully on disk, so finalize the local item IMMEDIATELY from the
        // metadata captured in the DownloadItem and notify JS right away. Completion must NEVER
        // depend on a network round-trip: previously the event was only sent from inside a
        // getLibraryItemWithProgress callback, so if that call hung or failed (server offline,
        // HTTP 429, or an expired token) the item wedged forever at "Download complete. Processing...".
        // The download-time snapshot is current (the user just tapped download); the app's normal
        // sync refreshes server-side progress afterward.
        DispatchQueue.main.async {
            self.finalizeDownloadedItem(downloadItem.asLibraryItem(), downloadItem: downloadItem, statusNotification: statusNotification)
        }
    }

    // Assemble the local library item from the finished parts and notify the JS layer exactly once.
    // Called with either the freshly-fetched server LibraryItem or a fallback rebuilt from the
    // DownloadItem, so completion is guaranteed regardless of server reachability.
    private func finalizeDownloadedItem(_ libraryItem: LibraryItem, downloadItem: DownloadItem, statusNotification: [String: Any]) {
        var statusNotification = statusNotification
        let localDirectory = libraryItem.id
        var coverFile: String?

        let files = downloadItem.downloadItemParts.enumerated().compactMap { _, part -> LocalFile? in
            var mimeType = part.mimeType()
            if part.filename == "cover.jpg" {
                coverFile = part.destinationUri
                mimeType = "image/jpg"
            }
            return LocalFile(libraryItem.id, part.filename!, mimeType!, part.destinationUri!, fileSize: Int(part.destinationURL!.fileSize))
        }
        var localLibraryItem = Database.shared.getLocalLibraryItem(byServerLibraryItemId: libraryItem.id)
        if (localLibraryItem != nil && localLibraryItem!.isPodcast) {
            try? Realm().write {
                try? localLibraryItem?.addFiles(files, item: libraryItem)
            }
        } else {
            localLibraryItem = LocalLibraryItem(libraryItem, localUrl: localDirectory, server: Store.serverConfig!, files: files, coverPath: coverFile)
            try? Database.shared.saveLocalLibraryItem(localLibraryItem: localLibraryItem!)
        }

        statusNotification["localLibraryItem"] = try? localLibraryItem.asDictionary()

        if let progress = libraryItem.userMediaProgress {
            let episode = downloadItem.media?.episodes.first(where: { $0.id == downloadItem.episodeId })
            let localMediaProgress = LocalMediaProgress(localLibraryItem: localLibraryItem!, episode: episode, progress: progress)
            try? localMediaProgress.save()
            statusNotification["localMediaProgress"] = try? localMediaProgress.asDictionary()
        }

        self.notifyListeners("onItemDownloadComplete", data: statusNotification)
    }
    
    
    // MARK: - Capacitor functions
    
    @objc func downloadLibraryItem(_ call: CAPPluginCall) {
        let libraryItemId = call.getString("libraryItemId")
        var episodeId = call.getString("episodeId")
        if ( episodeId == "null" ) { episodeId = nil }
        
        AbsLogger.info(message: "Download library item \(libraryItemId ?? "N/A") / episode \(episodeId ?? "N/A")")
        guard let libraryItemId = libraryItemId else { return call.resolve(["error": "libraryItemId not specified"]) }
        
        ApiClient.getLibraryItemWithProgress(libraryItemId: libraryItemId, episodeId: episodeId) { [weak self] libraryItem in
            if let libraryItem = libraryItem {
                AbsLogger.info(message: "Got library item from server \(libraryItem.id)")
                do {
                    if let episodeId = episodeId {
                        // Download a podcast episode
                        guard libraryItem.mediaType == "podcast" else { throw LibraryItemDownloadError.libraryItemNotPodcast }
                        let episode = libraryItem.media?.episodes.enumerated().first(where: { $1.id == episodeId })?.element
                        guard let episode = episode else { throw LibraryItemDownloadError.podcastEpisodeNotFound }
                        try self?.startLibraryItemDownload(libraryItem, episode: episode)
                    } else {
                        // Download a book
                        try self?.startLibraryItemDownload(libraryItem)
                    }
                    call.resolve()
                } catch {
                    debugPrint(error)
                    call.resolve(["error": "Failed to download"])
                }
            } else {
                call.resolve(["error": "Server request failed"])
            }
        }
    }
    
    private func startLibraryItemDownload(_ item: LibraryItem) throws {
        try startLibraryItemDownload(item, episode: nil)
    }
    
    private func startLibraryItemDownload(_ item: LibraryItem, episode: PodcastEpisode?) throws {
        let tracks = List<AudioTrack>()
        var episodeId: String?
        
        // Handle the different media type downloads
        switch item.mediaType {
        case "book":
            guard item.media?.tracks.count ?? 0 > 0 || item.media?.ebookFile != nil else { throw LibraryItemDownloadError.noTracks }
            item.media?.tracks.forEach { t in tracks.append(AudioTrack.detachCopy(of: t)!) }
        case "podcast":
            guard let episode = episode else { throw LibraryItemDownloadError.podcastEpisodeNotFound }
            guard let podcastTrack = episode.audioTrack else { throw LibraryItemDownloadError.noTracks }
            episodeId = episode.id
            tracks.append(AudioTrack.detachCopy(of: podcastTrack)!)
        default:
            throw LibraryItemDownloadError.unknownMediaType
        }
        
        // Queue up everything for downloading
        let downloadItem = DownloadItem(libraryItem: item, episodeId: episodeId, server: Store.serverConfig!)
        var tasks = [DownloadItemPartTask]()
        for (i, track) in tracks.enumerated() {
            let task = try startLibraryItemTrackDownload(downloadItemId: downloadItem.id!, item: item, position: i, track: track, episode: episode)
            downloadItem.downloadItemParts.append(task.part)
            tasks.append(task)
        }
        
        if (item.media?.ebookFile != nil) {
            let task = try startLibraryItemEbookDownload(downloadItemId: downloadItem.id!, item: item, ebookFile: item.media!.ebookFile!)
            downloadItem.downloadItemParts.append(task.part)
            tasks.append(task)
        }
        
        // Also download the cover
        if item.media?.coverPath != nil && !(item.media?.coverPath!.isEmpty ?? true) {
            if let task = try? startLibraryItemCoverDownload(downloadItemId: downloadItem.id!, item: item) {
                downloadItem.downloadItemParts.append(task.part)
                tasks.append(task)
            }
        }
        
        // Notify client of download item
        try? self.notifyListeners("onDownloadItem", data: downloadItem.asDictionary())
        
        // Persist in the database before status start coming in
        try Database.shared.saveDownloadItem(downloadItem)

        // Add all tasks to the download queue
        downloadQueueLock.lock()
        // Clear any stale "already finalized" marker so a re-download of the same item finalizes again.
        if let itemId = downloadItem.id { finalizedItemIds.remove(itemId) }
        for t in tasks {
            let url = t.task.originalRequest?.url ?? t.part.downloadURL!
            pendingDownloadTasks.append(PendingDownload(partId: t.partId, filename: t.filename, downloadURL: url, task: t.task))
        }
        downloadQueueLock.unlock()

        AbsLogger.info(message: "Added \(tasks.count) tasks to download queue. Starting downloads...")

        // Start downloading (up to maxConcurrentDownloads at a time)
        startNextDownloadInQueue()
    }
    
    private func startLibraryItemTrackDownload(downloadItemId: String, item: LibraryItem, position: Int, track: AudioTrack, episode: PodcastEpisode?) throws -> DownloadItemPartTask {
        AbsLogger.info(message: "TRACK \(track.contentUrl!)")

        // If we don't name metadata, then we can't proceed
        guard let filename = track.metadata?.filename else {
            throw LibraryItemDownloadError.noMetadata
        }

        let serverUrl = urlForTrack(item: item, track: track)
        let itemDirectory = try createLibraryItemFileDirectory(item: item)
        let localUrl = "\(itemDirectory)/\(filename)"

        let task = session.downloadTask(with: serverUrl)
        let part = DownloadItemPart(downloadItemId: downloadItemId, filename: filename, destination: localUrl, itemTitle: track.title ?? "Unknown", serverPath: Store.serverConfig!.address, audioTrack: track, episode: episode, ebookFile: nil, size: track.metadata?.size ?? 0)

        // Store the id on the task so the download item can be pulled from the database later
        task.taskDescription = part.id

        return DownloadItemPartTask(part: part, task: task, partId: part.id, filename: filename)
    }
    
    private func startLibraryItemEbookDownload(downloadItemId: String, item: LibraryItem, ebookFile: EBookFile) throws -> DownloadItemPartTask {
        let filename = ebookFile.metadata?.filename ?? "ebook.\(ebookFile.ebookFormat)"
        let serverPath = "/api/items/\(item.id)/file/\(ebookFile.ino)/download"
        let itemDirectory = try createLibraryItemFileDirectory(item: item)
        let localUrl = "\(itemDirectory)/\(filename)"

        let part = DownloadItemPart(downloadItemId: downloadItemId, filename: filename, destination: localUrl, itemTitle: filename, serverPath: serverPath, audioTrack: nil, episode: nil, ebookFile: ebookFile, size: ebookFile.metadata?.size ?? 0)
        let task = session.downloadTask(with: part.downloadURL!)

        // Store the id on the task so the download item can be pulled from the database later
        task.taskDescription = part.id

        return DownloadItemPartTask(part: part, task: task, partId: part.id, filename: filename)
    }
    
    private func startLibraryItemCoverDownload(downloadItemId: String, item: LibraryItem) throws -> DownloadItemPartTask {
        let filename = "cover.jpg"
        let serverPath = "/api/items/\(item.id)/cover"
        let itemDirectory = try createLibraryItemFileDirectory(item: item)
        let localUrl = "\(itemDirectory)/\(filename)"

        // Find library file to get cover size
        let coverLibraryFile = item.libraryFiles.first(where: {
            $0.metadata?.path == item.media?.coverPath
        })

        let part = DownloadItemPart(downloadItemId: downloadItemId, filename: filename, destination: localUrl, itemTitle: "cover", serverPath: serverPath, audioTrack: nil, episode: nil, ebookFile: nil, size: coverLibraryFile?.metadata?.size ?? 0)
        let task = session.downloadTask(with: part.downloadURL!)

        // Store the id on the task so the download item can be pulled from the database later
        task.taskDescription = part.id

        return DownloadItemPartTask(part: part, task: task, partId: part.id, filename: filename)
    }
    
    private func urlForTrack(item: LibraryItem, track: AudioTrack) -> URL {
        // TODO: Future server release should include ino with AudioFile or FileMetadata
        let trackPath = track.metadata?.path ?? ""
        
        var audioFileIno = ""
        if (item.mediaType == "podcast") {
            let podcastEpisodes = item.media?.episodes ?? List<PodcastEpisode>()
            let matchingEpisode = podcastEpisodes.first(where: { $0.audioFile?.metadata?.path == trackPath })
            audioFileIno = matchingEpisode?.audioFile?.ino ?? ""
        } else {
            let audioFiles = item.media?.audioFiles ?? List<AudioFile>()
            let matchingAudioFile = audioFiles.first(where: { $0.metadata?.path == trackPath })
            audioFileIno = matchingAudioFile?.ino ?? ""
        }

        let urlstr = "\(Store.serverConfig!.address)/api/items/\(item.id)/file/\(audioFileIno)/download?token=\(Store.serverConfig!.token)"
        return URL(string: urlstr)!
    }
    
    private func createLibraryItemFileDirectory(item: LibraryItem) throws -> String {
        let itemDirectory = item.id
        AbsLogger.info(message: "ITEM DIR \(itemDirectory)")
        
        guard AbsDownloader.itemDownloadFolder(path: itemDirectory) != nil else {
            AbsLogger.error(message: "Failed to CREATE LI DIRECTORY \(itemDirectory)")
            throw LibraryItemDownloadError.failedDirectory
        }
        
        return itemDirectory
    }
    
    static func itemDownloadFolder(path: String) -> URL? {
        do {
            var itemFolder = AbsDownloader.downloadsDirectory.appendingPathComponent(path)
            
            if !FileManager.default.fileExists(atPath: itemFolder.path) {
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
            }
            
            // Make sure we don't backup download files to iCloud
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try itemFolder.setResourceValues(resourceValues)
            
            return itemFolder
        } catch {
            AbsLogger.error(message: "Failed to CREATE LI DIRECTORY \(error)", error: error)
            return nil
        }
    }
    
}


// MARK: - Class structs

typealias DownloadProgressHandler = (_ downloadItem: DownloadItem, _ downloadItemPart: DownloadItemPart) throws -> Void

struct DownloadItemPartTask {
    let part: DownloadItemPart
    let task: URLSessionDownloadTask
    let partId: String // Cache the ID to avoid cross-thread Realm access
    let filename: String // Cache the filename to avoid cross-thread Realm access
}

// Queued (not yet resumed) download. Carries only value-type/thread-safe fields — no Realm object.
struct PendingDownload {
    let partId: String
    let filename: String
    let downloadURL: URL
    let task: URLSessionDownloadTask
}

// In-flight download plus the bookkeeping the stall watchdog needs.
struct ActiveDownload {
    let partId: String
    let filename: String
    let downloadURL: URL
    let task: URLSessionDownloadTask
    var lastBytesWritten: Int64
    var lastProgressAt: Date
}

enum LibraryItemDownloadError: String, Error {
    case noTracks = "No tracks on library item"
    case noMetadata = "No metadata for track, unable to download"
    case libraryItemNotPodcast = "Library item is not a podcast but episode was requested"
    case podcastEpisodeNotFound = "Invalid podcast episode not found"
    case podcastOnlySupported = "Only podcasts are supported for this function"
    case unknownMediaType = "Unknown media type"
    case failedDirectory = "Failed to create directory"
    case failedDownload = "Failed to download item"
    case noTaskDescription = "No task description"
    case downloadItemNotFound = "DownloadItem not found"
    case downloadItemPartNotFound = "DownloadItemPart not found"
    case downloadItemPartDestinationUrlNotDefined = "DownloadItemPart destination URL not defined"
    case libraryItemNotFound = "LibraryItem not found for id"
}
