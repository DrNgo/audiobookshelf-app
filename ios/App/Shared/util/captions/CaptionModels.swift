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
