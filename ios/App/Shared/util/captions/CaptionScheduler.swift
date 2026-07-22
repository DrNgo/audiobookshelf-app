//
//  CaptionScheduler.swift
//  Audiobookshelf
//
//  Keeps a window of transcribed audio ahead of the playhead. Exactly one engine
//  job runs at a time; once the window is full the scheduler idles at zero CPU.
//

import Foundation

actor CaptionScheduler {

    private let tracks: [CaptionTrack]
    private let fileURLs: [String: URL]
    private let store: CaptionStore
    private let engine: SegmentProducing
    private let locale: String
    private let windowAhead: Double
    private let refillMargin: Double
    private let onSegments: @Sendable ([CaptionSegment]) -> Void
    private let logger = AppLogger(category: "CaptionScheduler")

    private var segments: [CaptionSegment] = []
    private var playhead: Double = 0
    private var isRunning = false
    private var isSuspended = false
    private var isFilling = false
    private var fillTask: Task<Void, Never>?
    /// Bumped whenever in-flight work is superseded (seek/stop/suspend). A fill
    /// task compares its captured generation against this on completion and does
    /// nothing if it was superseded — this is what makes a stale task's return
    /// harmless instead of letting it clobber the newer task's handle.
    private var generation = 0
    /// Book-time ranges the engine failed on. A failed gap is dammed (not
    /// re-requested) until a seek clears it. Range-keyed, not point-keyed:
    /// a request's bookOffset advances with the playhead while a gap stays
    /// uncovered, so a point key wouldn't suppress the repeat.
    private var failedRanges: [Range<Double>] = []

    init(tracks: [CaptionTrack],
         fileURLs: [String: URL],
         store: CaptionStore,
         engine: SegmentProducing,
         locale: String,
         windowAhead: Double = 600,
         refillMargin: Double = 300,
         onSegments: @escaping @Sendable ([CaptionSegment]) -> Void) {
        self.tracks = tracks
        self.fileURLs = fileURLs
        self.store = store
        self.engine = engine
        self.locale = locale
        self.windowAhead = windowAhead
        self.refillMargin = refillMargin
        self.onSegments = onSegments
    }

    func start(at bookTime: Double) {
        isRunning = true
        playhead = bookTime

        // Serve the cache first so captions paint immediately.
        segments = store.load(locale: locale)
        if !segments.isEmpty {
            onSegments(segments)
        }
        scheduleFillIfNeeded()
    }

    func seek(to bookTime: Double) {
        playhead = bookTime
        // Clear the latch so the refill trigger is re-evaluated at the new
        // position — a backward seek into cached audio must issue no work.
        isFilling = false
        // A seek is a fresh chance for any region that failed before.
        failedRanges.removeAll()
        supersedeInFlight()
        scheduleFillIfNeeded()
    }

    /// Called as the playhead advances, to top the window back up.
    func advance(to bookTime: Double) {
        playhead = bookTime
        scheduleFillIfNeeded()
    }

    func stop() {
        isRunning = false
        isFilling = false
        supersedeInFlight()
    }

    /// Backgrounding suspends work; foregrounding resumes it. Captions never
    /// request background execution time.
    func suspend() {
        isSuspended = true
        isFilling = false
        supersedeInFlight()
    }

    /// Cancel the current fill and bump the generation so its late completion
    /// is a no-op rather than clobbering whatever replaces it.
    private func supersedeInFlight() {
        generation += 1
        fillTask?.cancel()
        fillTask = nil
    }

    func resume() {
        isSuspended = false
        guard isRunning else { return }
        scheduleFillIfNeeded()
    }

    /// Test hook: wait for the in-flight fill chain to settle. Each non-superseded
    /// `runFill` either clears `fillTask` or replaces it with the next task before
    /// its value resolves, so looping until `fillTask == nil` drains the chain.
    func drainForTesting() async {
        while let task = fillTask {
            await task.value
        }
    }

    /// Hysteresis matters here. The *trigger* is the refill margin, but once
    /// triggered we fill all the way to `windowAhead`. Without the `isFilling`
    /// latch, every one-second playhead advance would issue a one-second
    /// request, and requests clipped at track boundaries would never chain.
    private func scheduleFillIfNeeded() {
        guard isRunning, !isSuspended, fillTask == nil else { return }

        let frontier = CaptionTimeline.coveredUntil(from: playhead, segments: segments)

        if !isFilling {
            guard frontier < playhead + refillMargin else { return }
            isFilling = true
        }

        guard frontier < playhead + windowAhead,
              let request = CaptionTimeline.nextRequest(playhead: playhead,
                                                        segments: segments,
                                                        tracks: tracks,
                                                        windowAhead: windowAhead),
              // Don't re-request a gap that already failed at this position.
              !failedRanges.contains(where: { $0.contains(request.bookOffset) })
        else {
            isFilling = false
            return
        }

        generation += 1
        let gen = generation
        fillTask = Task { [weak self] in
            await self?.runFill(request, generation: gen)
        }
    }

    private func runFill(_ request: TranscriptionRequest, generation gen: Int) async {
        var produced: [CaptionSegment] = []
        var failed = false

        if let fileURL = fileURLs[request.localFileId] {
            do {
                for try await segment in engine.transcribe(request: request, fileURL: fileURL) {
                    if Task.isCancelled { break }
                    produced.append(segment)
                }
            } catch {
                // A failed region is left uncovered rather than retried forever;
                // playback must never be disturbed by transcription trouble.
                logger.error("Caption transcription failed at \(request.bookOffset)s: \(error)")
                failed = true
            }
        } else {
            logger.error("Caption track file missing for id \(request.localFileId)")
            failed = true
        }

        // Superseded by a seek/stop/suspend (or a newer fill): discard silently,
        // and do NOT touch fillTask — it now belongs to the newer work.
        guard gen == generation else { return }
        fillTask = nil

        if failed {
            // Record the failure so the same gap isn't retried; leave isFilling
            // clear so a later advance/seek can re-evaluate.
            failedRanges.append(request.bookOffset ..< (request.bookOffset + request.duration))
            isFilling = false
            return
        }

        if !produced.isEmpty {
            segments.append(contentsOf: produced)
            segments.sort { $0.start < $1.start }
            try? store.append(produced, locale: locale)
            onSegments(produced)
        }

        if isRunning { scheduleFillIfNeeded() }
    }
}
