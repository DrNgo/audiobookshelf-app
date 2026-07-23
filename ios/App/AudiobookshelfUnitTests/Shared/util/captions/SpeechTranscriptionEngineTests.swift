//
//  SpeechTranscriptionEngineTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
import AVFoundation
@testable import Audiobookshelf

@available(iOS 26.0, *)
final class SpeechTranscriptionEngineTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "speech-sample", withExtension: "m4a"),
                                "speech-sample.m4a is not in Copy Bundle Resources")
        return url
    }

    func testLocaleAvailability() async throws {
        // `await` can't live inside XCTSkipUnless's non-async autoclosure, so the
        // async availability check is resolved first, then handed over as a Bool.
        let available = await SpeechTranscriptionEngine.isAvailable(locale: Locale(identifier: "en-US"))
        try XCTSkipUnless(available, "en-US speech model unavailable on this machine")
    }

    func testProducesTimedSegmentsShiftedIntoBookTime() async throws {
        let locale = Locale(identifier: "en-US")
        let available = await SpeechTranscriptionEngine.isAvailable(locale: locale)
        try XCTSkipUnless(available, "en-US speech model unavailable on this machine")
        try await SpeechTranscriptionEngine.prepareModel(locale: locale)

        let engine = SpeechTranscriptionEngine(locale: locale)
        // bookOffset of 1000 proves the engine shifts file-relative recognizer
        // times into book time rather than leaking raw file offsets.
        let request = TranscriptionRequest(localFileId: "fixture",
                                           offsetInTrack: 0,
                                           duration: 15,
                                           bookOffset: 1000)

        var segments: [CaptionSegment] = []
        for try await segment in engine.transcribe(request: request, fileURL: try fixtureURL()) {
            segments.append(segment)
        }

        XCTAssertFalse(segments.isEmpty, "expected at least one segment from 15s of speech")
        let first = try XCTUnwrap(segments.first)
        XCTAssertGreaterThanOrEqual(first.start, 1000, "times must be shifted by bookOffset")
        XCTAssertLessThan(first.start, 1020, "times must not run past the requested duration")
        XCTAssertFalse(first.words.isEmpty, "audioTimeRange attribute produced no word timings")
        XCTAssertFalse(first.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
