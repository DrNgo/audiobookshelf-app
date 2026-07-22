//
//  CaptionTimelineTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionTimelineTests: XCTestCase {

    // A three-track book: 0-100, 100-250, 250-400 (book seconds).
    private let tracks = [
        CaptionTrack(index: 0, startOffset: 0, duration: 100, localFileId: "f0"),
        CaptionTrack(index: 1, startOffset: 100, duration: 150, localFileId: "f1"),
        CaptionTrack(index: 2, startOffset: 250, duration: 150, localFileId: "f2"),
    ]

    func testPlacementInFirstTrack() {
        let p = CaptionTimeline.placement(forBookTime: 42, tracks: tracks)
        XCTAssertEqual(p?.track.index, 0)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 42, accuracy: 0.001)
    }

    func testPlacementInMiddleTrackSubtractsStartOffset() {
        let p = CaptionTimeline.placement(forBookTime: 160, tracks: tracks)
        XCTAssertEqual(p?.track.index, 1)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 60, accuracy: 0.001)
    }

    // A boundary time belongs to the track it starts, not the one it ends.
    func testExactBoundaryBelongsToLaterTrack() {
        let p = CaptionTimeline.placement(forBookTime: 100, tracks: tracks)
        XCTAssertEqual(p?.track.index, 1)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 0, accuracy: 0.001)
    }

    func testTimeBeyondLastTrackReturnsNil() {
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 400, tracks: tracks))
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 9999, tracks: tracks))
    }

    func testNegativeTimeClampsToFirstTrack() {
        let p = CaptionTimeline.placement(forBookTime: -5, tracks: tracks)
        XCTAssertEqual(p?.track.index, 0)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 0, accuracy: 0.001)
    }

    func testEmptyTrackListReturnsNil() {
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 10, tracks: []))
    }

    private func seg(_ start: Double, _ end: Double) -> CaptionSegment {
        CaptionSegment(start: start, end: end, text: "x",
                       words: [CaptionWord(start: start, end: end, text: "x")])
    }

    // MARK: coveredUntil

    func testCoveredUntilReturnsPlayheadWhenNothingCovers() {
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 50, segments: [seg(200, 210)]), 50, accuracy: 0.001)
    }

    func testCoveredUntilFollowsContiguousRun() {
        let segs = [seg(40, 50), seg(50, 60), seg(60, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    // A gap larger than the join tolerance stops the run.
    func testCoveredUntilStopsAtGap() {
        let segs = [seg(40, 50), seg(58, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 50, accuracy: 0.001)
    }

    // Sub-second silences between segments are normal speech, not gaps.
    func testCoveredUntilToleratesSmallGaps() {
        let segs = [seg(40, 50), seg(50.4, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    func testCoveredUntilHandlesUnsortedSegments() {
        let segs = [seg(60, 70), seg(40, 50), seg(50, 60)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    // MARK: nextRequest

    func testNextRequestFillsFromPlayheadWhenNothingCached() {
        let r = CaptionTimeline.nextRequest(playhead: 10, segments: [], tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.localFileId, "f0")
        XCTAssertEqual(r?.offsetInTrack ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(r?.bookOffset ?? -1, 10, accuracy: 0.001)
        // Clipped to the end of track 0 (100s), not the full 600s window.
        XCTAssertEqual(r?.duration ?? -1, 90, accuracy: 0.001)
    }

    // The request must never span two files — the engine reads one file at a time.
    func testNextRequestIsClippedToTrackBoundary() {
        let r = CaptionTimeline.nextRequest(playhead: 240, segments: [], tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.localFileId, "f1")
        XCTAssertEqual(r?.offsetInTrack ?? -1, 140, accuracy: 0.001)
        XCTAssertEqual(r?.duration ?? -1, 10, accuracy: 0.001)
    }

    func testNextRequestResumesAfterCachedCoverage() {
        let segs = [seg(10, 20), seg(20, 30)]
        let r = CaptionTimeline.nextRequest(playhead: 10, segments: segs, tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.bookOffset ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(r?.offsetInTrack ?? -1, 30, accuracy: 0.001)
    }

    func testNextRequestReturnsNilWhenWindowIsFull() {
        let segs = [seg(10, 700)]
        XCTAssertNil(CaptionTimeline.nextRequest(playhead: 10, segments: segs, tracks: tracks, windowAhead: 600))
    }

    func testNextRequestReturnsNilPastEndOfBook() {
        XCTAssertNil(CaptionTimeline.nextRequest(playhead: 400, segments: [], tracks: tracks, windowAhead: 600))
    }
}
