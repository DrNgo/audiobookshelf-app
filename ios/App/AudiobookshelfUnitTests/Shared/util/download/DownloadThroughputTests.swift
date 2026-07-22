//
//  DownloadThroughputTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class DownloadThroughputTests: XCTestCase {

    func testMegabytesPerSecond() {
        XCTAssertEqual(DownloadThroughput.megabytesPerSecond(bytes: 10_000_000, seconds: 4), 2.5, accuracy: 0.001)
    }

    func testRateIsZeroRatherThanInfiniteForAZeroInterval() {
        XCTAssertEqual(DownloadThroughput.megabytesPerSecond(bytes: 5_000_000, seconds: 0), 0)
        XCTAssertEqual(DownloadThroughput.megabytesPerSecond(bytes: 0, seconds: 5), 0)
    }

    func testDescribeBytesSwitchesToGigabytes() {
        XCTAssertEqual(DownloadThroughput.describeBytes(12_400_000), "12.4 MB")
        XCTAssertEqual(DownloadThroughput.describeBytes(2_500_000_000), "2.50 GB")
    }

    func testPercentIsNilWithoutAContentLength() {
        XCTAssertNil(DownloadThroughput.percent(written: 100, expected: 0))
        XCTAssertNil(DownloadThroughput.percent(written: 100, expected: -1))
        XCTAssertEqual(DownloadThroughput.percent(written: 25, expected: 100)!, 25, accuracy: 0.001)
    }

    func testSecondsRemainingUsesTheAverageRate() {
        // 50 MB done in 10s => 5 MB/s; 50 MB left => 10s
        let remaining = DownloadThroughput.secondsRemaining(written: 50_000_000, expected: 100_000_000, elapsed: 10)
        XCTAssertEqual(remaining!, 10, accuracy: 0.001)
    }

    func testSecondsRemainingIsNilWhenItCannotBeEstimated() {
        XCTAssertNil(DownloadThroughput.secondsRemaining(written: 0, expected: 100, elapsed: 5))
        XCTAssertNil(DownloadThroughput.secondsRemaining(written: 100, expected: 100, elapsed: 5))
        XCTAssertNil(DownloadThroughput.secondsRemaining(written: 50, expected: 100, elapsed: 0))
    }
}
