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
}
