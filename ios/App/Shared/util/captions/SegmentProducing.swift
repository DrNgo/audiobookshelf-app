//
//  SegmentProducing.swift
//  Audiobookshelf
//
//  The seam between the scheduler and speech recognition. The scheduler depends
//  only on this, which is why it compiles and tests without any iOS 26 symbol.
//

import Foundation

protocol SegmentProducing: Sendable {
    /// Segments for `request`, with times already shifted into book-global time.
    /// The stream finishes when the requested duration is exhausted.
    func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error>
}
