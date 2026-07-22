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

    /// Segments separated by less than this are treated as one contiguous run.
    /// Ordinary sentence pauses in narration land well under half a second.
    static let joinTolerance: Double = 0.5

    /// Walk forward from `playhead` through contiguous segment coverage and
    /// return the book time where that coverage runs out.
    static func coveredUntil(from playhead: Double, segments: [CaptionSegment]) -> Double {
        let sorted = segments.sorted { $0.start < $1.start }
        var frontier = playhead
        for segment in sorted {
            if segment.end <= frontier { continue }
            guard segment.start <= frontier + joinTolerance else { break }
            frontier = segment.end
        }
        return frontier
    }

    /// The next unit of work needed to keep `windowAhead` seconds decoded past
    /// the playhead, or nil if the window is already full or the book has ended.
    static func nextRequest(playhead: Double,
                            segments: [CaptionSegment],
                            tracks: [CaptionTrack],
                            windowAhead: Double) -> TranscriptionRequest? {
        let frontier = coveredUntil(from: playhead, segments: segments)
        let target = playhead + windowAhead
        guard frontier < target else { return nil }
        guard let placement = placement(forBookTime: frontier, tracks: tracks) else { return nil }

        // Clip to the end of this track's file — one request never spans two files.
        let remainingInTrack = placement.track.endOffset - frontier
        let duration = min(target - frontier, remainingInTrack)
        guard duration > 0 else { return nil }

        return TranscriptionRequest(localFileId: placement.track.localFileId,
                                    offsetInTrack: placement.offsetInTrack,
                                    duration: duration,
                                    bookOffset: frontier)
    }
}
