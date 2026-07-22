//
//  DownloadThroughput.swift
//  Audiobookshelf
//
//  Formatting + rate maths for download progress instrumentation.
//

import Foundation

enum DownloadThroughput {

    /// How often a transfer reports its rate to the log.
    static let logInterval: TimeInterval = 10

    static func megabytesPerSecond(bytes: Int64, seconds: TimeInterval) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return (Double(bytes) / 1_000_000.0) / seconds
    }

    static func describeBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000.0
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
        return String(format: "%.1f MB", mb)
    }

    static func describeRate(_ mbPerSecond: Double) -> String {
        String(format: "%.2f MB/s", mbPerSecond)
    }

    /// Percentage complete, or nil when the server didn't send a length we can use.
    static func percent(written: Int64, expected: Int64) -> Double? {
        guard expected > 0 else { return nil }
        return (Double(written) / Double(expected)) * 100
    }

    /// Seconds remaining at the average rate so far, or nil if it can't be estimated.
    static func secondsRemaining(written: Int64, expected: Int64, elapsed: TimeInterval) -> TimeInterval? {
        guard expected > written, written > 0, elapsed > 0 else { return nil }
        let bytesPerSecond = Double(written) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        return Double(expected - written) / bytesPerSecond
    }
}
