//
//  CaptionTimeline.swift
//  Audiobookshelf
//
//  Pure arithmetic mapping book-global time onto downloaded track files.
//  No Realm, no Speech, no I/O — this is the unit that carries the real bugs.
//

import Foundation

enum CaptionTimeline {

    /// Locate a book-global time within the track list.
    /// A time exactly on a boundary belongs to the track it *starts*.
    /// Returns nil past the end of the last track, or for an empty list.
    static func placement(forBookTime bookTime: Double, tracks: [CaptionTrack]) -> TrackPlacement? {
        guard !tracks.isEmpty else { return nil }
        let sorted = tracks.sorted { $0.startOffset < $1.startOffset }
        let clamped = max(bookTime, sorted[0].startOffset)

        guard let track = sorted.last(where: { $0.startOffset <= clamped }) else { return nil }
        guard clamped < track.endOffset else { return nil }

        return TrackPlacement(track: track, offsetInTrack: clamped - track.startOffset)
    }
}
