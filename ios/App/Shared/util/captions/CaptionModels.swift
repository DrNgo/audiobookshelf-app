//
//  CaptionModels.swift
//  Audiobookshelf
//
//  Value types shared by the caption timeline, store, scheduler, and engine.
//  Every time in these types is book-global seconds unless the name says otherwise.
//

import Foundation

struct CaptionWord: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct CaptionSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let words: [CaptionWord]
}

/// A downloaded audio track, flattened out of Realm so the timeline stays testable.
struct CaptionTrack: Equatable {
    let index: Int
    let startOffset: Double
    let duration: Double
    let localFileId: String

    var endOffset: Double { startOffset + duration }
}

struct TrackPlacement: Equatable {
    let track: CaptionTrack
    /// Seconds from the start of this track's file.
    let offsetInTrack: Double
}

/// One contiguous unit of work for the engine. Never spans more than one file.
struct TranscriptionRequest: Equatable {
    let localFileId: String
    /// Seconds from the start of the file to begin reading.
    let offsetInTrack: Double
    /// Seconds of audio to read.
    let duration: Double
    /// The book-global time corresponding to `offsetInTrack`, used to shift
    /// file-relative recognizer timings back into book time.
    let bookOffset: Double
}
