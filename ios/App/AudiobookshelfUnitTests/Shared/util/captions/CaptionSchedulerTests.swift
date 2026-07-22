//
//  CaptionSchedulerTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

/// Records every request it receives and emits one segment covering the whole span.
private actor FakeEngine: SegmentProducing {
    private var recorded: [TranscriptionRequest] = []

    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                let segment = CaptionSegment(
                    start: request.bookOffset,
                    end: request.bookOffset + request.duration,
                    text: "seg@\(Int(request.bookOffset))",
                    words: [CaptionWord(start: request.bookOffset,
                                        end: request.bookOffset + request.duration,
                                        text: "seg")]
                )
                continuation.yield(segment)
                continuation.finish()
            }
        }
    }

    private func record(_ r: TranscriptionRequest) { recorded.append(r) }
    func recordedRequests() -> [TranscriptionRequest] { recorded }
}

private actor FailingEngine: SegmentProducing {
    struct Boom: Error {}
    private var calls = 0
    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.bump()
                continuation.finish(throwing: Boom())
            }
        }
    }
    private func bump() { calls += 1 }
    func callCount() -> Int { calls }
}

final class CaptionSchedulerTests: XCTestCase {

    private var dir: URL!

    private let tracks = [
        CaptionTrack(index: 0, startOffset: 0, duration: 100, localFileId: "f0"),
        CaptionTrack(index: 1, startOffset: 100, duration: 150, localFileId: "f1"),
    ]

    private var fileURLs: [String: URL] {
        ["f0": dir.appendingPathComponent("f0.m4b"),
         "f1": dir.appendingPathComponent("f1.m4b")]
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeScheduler(engine: SegmentProducing,
                               store: CaptionStore? = nil,
                               windowAhead: Double = 60,
                               onSegments: @escaping @Sendable ([CaptionSegment]) -> Void = { _ in }) -> CaptionScheduler {
        CaptionScheduler(tracks: tracks,
                         fileURLs: fileURLs,
                         store: store ?? CaptionStore(directory: dir),
                         engine: engine,
                         locale: "en-US",
                         windowAhead: windowAhead,
                         refillMargin: 30,
                         onSegments: onSegments)
    }

    func testStartFillsTheWindowFromThePlayhead() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.first?.bookOffset ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(requests.first?.localFileId, "f0")
    }

    func testSchedulerStopsOnceWindowIsFull() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        // One 60s request fills a 60s window; it must not keep requesting.
        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRequestsChainAcrossATrackBoundary() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 120)
        await scheduler.start(at: 40)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].localFileId, "f0")
        XCTAssertEqual(requests[0].duration, 60, accuracy: 0.001)
        XCTAssertEqual(requests[1].localFileId, "f1")
        XCTAssertEqual(requests[1].offsetInTrack, 0, accuracy: 0.001)
    }

    func testCachedSegmentsAreEmittedWithoutCallingTheEngine() async throws {
        let store = CaptionStore(directory: dir)
        try store.append([CaptionSegment(start: 0, end: 90, text: "cached",
                                         words: [CaptionWord(start: 0, end: 90, text: "cached")])],
                         locale: "en-US")

        let engine = FakeEngine()
        let box = SegmentBox()
        let scheduler = makeScheduler(engine: engine, store: store, windowAhead: 60) { segs in
            box.append(segs)
        }
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        let requestCount = await engine.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(box.all().map(\.text), ["cached"])
    }

    func testProducedSegmentsArePersisted() async {
        let store = CaptionStore(directory: dir)
        let scheduler = makeScheduler(engine: FakeEngine(), store: store, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        XCTAssertFalse(store.load(locale: "en-US").isEmpty)
    }

    func testSeekBackwardIntoCachedAudioMakesNoNewRequests() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.seek(to: 10)
        await scheduler.drainForTesting()

        let requestCount = await engine.recordedRequests().count
        XCTAssertEqual(requestCount, afterStart)
    }

    func testSeekForwardRequestsTheNewRegion() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        await scheduler.seek(to: 200)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertTrue(requests.contains { abs($0.bookOffset - 200) < 0.001 })
    }

    func testStopPreventsFurtherRequests() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.stop()
        await scheduler.advance(to: 400)
        await scheduler.drainForTesting()

        let requestCount = await engine.recordedRequests().count
        XCTAssertEqual(requestCount, afterStart,
                       "a stopped scheduler must issue no work when the playhead advances")
    }

    func testSuspendStopsWorkAndResumeRestartsIt() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.suspend()
        await scheduler.advance(to: 55)
        await scheduler.drainForTesting()
        let duringSuspend = await engine.recordedRequests().count
        XCTAssertEqual(duringSuspend, afterStart,
                       "a suspended scheduler must not transcribe in the background")

        await scheduler.resume()
        await scheduler.drainForTesting()
        let afterResume = await engine.recordedRequests().count
        XCTAssertGreaterThan(afterResume, afterStart,
                             "resuming must top the window back up")
    }

    // An engine failure must not wedge the scheduler, crash playback, or
    // retry the same failing gap forever.
    func testEngineFailureIsSwallowedAndNotRetried() async {
        let engine = FailingEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let callsAfterStart = await engine.callCount()
        XCTAssertEqual(callsAfterStart, 1,
                       "a failed gap must be attempted once, not retried in a loop")

        // Advancing within the same still-failed region must not re-attempt it.
        await scheduler.advance(to: 5)
        await scheduler.drainForTesting()
        let callsAfterAdvance = await engine.callCount()
        XCTAssertEqual(callsAfterAdvance, 1,
                       "advancing over a known-failed gap must not re-request it")

        // A seek is a fresh chance — the failed offset set is cleared.
        await scheduler.seek(to: 0)
        await scheduler.drainForTesting()
        let callsAfterSeek = await engine.callCount()
        XCTAssertEqual(callsAfterSeek, 2, "a seek should retry the failed region once")
    }
}

/// Thread-safe collector for the onSegments callback.
private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [CaptionSegment] = []
    func append(_ s: [CaptionSegment]) { lock.lock(); segments += s; lock.unlock() }
    func all() -> [CaptionSegment] { lock.lock(); defer { lock.unlock() }; return segments }
}
