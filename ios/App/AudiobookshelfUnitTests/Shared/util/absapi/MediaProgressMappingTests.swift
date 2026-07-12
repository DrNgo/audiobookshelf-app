//
//  MediaProgressMappingTests.swift
//  AudiobookshelfUnitTests
//
//  Phase 1 of the ABSApiClient migration: verifies the DTO <-> Realm mapping for
//  media progress. The generated DTO uses all-optional properties and Int (ms) timestamps;
//  the Realm model uses non-optional Double fields with defaults.
//

import XCTest
import ABSApiClient
@testable import Audiobookshelf

final class MediaProgressMappingTests: XCTestCase {

    func testFromDTOMapsAllFields() {
        let dto = Components.Schemas.mediaProgress(
            id: "li_1",
            userId: "u_1",
            libraryItemId: "li_1",
            episodeId: "ep_1",
            duration: 3600.5,
            progress: 0.25,
            currentTime: 900.5,
            isFinished: true,
            ebookLocation: "epubcfi(/6/8)",
            ebookProgress: 0.1,
            lastUpdate: 1633522963509,
            startedAt: 1600000000000,
            finishedAt: 1700000000000
        )

        let mp = MediaProgress.from(dto: dto)

        XCTAssertEqual(mp.id, "li_1")
        XCTAssertEqual(mp.userId, "u_1")
        XCTAssertEqual(mp.libraryItemId, "li_1")
        XCTAssertEqual(mp.episodeId, "ep_1")
        XCTAssertEqual(mp.duration, 3600.5)
        XCTAssertEqual(mp.progress, 0.25)
        XCTAssertEqual(mp.currentTime, 900.5)
        XCTAssertTrue(mp.isFinished)
        XCTAssertEqual(mp.ebookLocation, "epubcfi(/6/8)")
        XCTAssertEqual(mp.ebookProgress, 0.1)
        // Int (ms) -> Double
        XCTAssertEqual(mp.lastUpdate, 1633522963509)
        XCTAssertEqual(mp.startedAt, 1600000000000)
        XCTAssertEqual(mp.finishedAt, 1700000000000)
    }

    func testFromDTONilOptionalsUseRealmDefaults() {
        let dto = Components.Schemas.mediaProgress(id: "only_id")

        let mp = MediaProgress.from(dto: dto)

        XCTAssertEqual(mp.id, "only_id")
        XCTAssertEqual(mp.userId, "")
        XCTAssertEqual(mp.libraryItemId, "")
        XCTAssertNil(mp.episodeId)
        XCTAssertEqual(mp.duration, 0)
        XCTAssertEqual(mp.progress, 0)
        XCTAssertEqual(mp.currentTime, 0)
        XCTAssertFalse(mp.isFinished)
        XCTAssertNil(mp.ebookLocation)
        XCTAssertNil(mp.ebookProgress)
        XCTAssertEqual(mp.lastUpdate, 0)
        XCTAssertEqual(mp.startedAt, 0)
        XCTAssertNil(mp.finishedAt)
    }

    func testToDTOMapsAllFields() {
        let mp = MediaProgress()
        mp.id = "li_2"
        mp.userId = "u_2"
        mp.libraryItemId = "li_2"
        mp.episodeId = "ep_2"
        mp.duration = 1234.5
        mp.progress = 0.5
        mp.currentTime = 600
        mp.isFinished = true
        mp.ebookLocation = "loc"
        mp.ebookProgress = 0.9
        mp.lastUpdate = 1633522963509
        mp.startedAt = 1600000000000
        mp.finishedAt = 1700000000000

        let dto = mp.toDTO()

        XCTAssertEqual(dto.id, "li_2")
        XCTAssertEqual(dto.userId, "u_2")
        XCTAssertEqual(dto.libraryItemId, "li_2")
        XCTAssertEqual(dto.episodeId, "ep_2")
        XCTAssertEqual(dto.duration, 1234.5)
        XCTAssertEqual(dto.progress, 0.5)
        XCTAssertEqual(dto.currentTime, 600)
        XCTAssertEqual(dto.isFinished, true)
        XCTAssertEqual(dto.ebookLocation, "loc")
        XCTAssertEqual(dto.ebookProgress, 0.9)
        // Double -> Int (ms)
        XCTAssertEqual(dto.lastUpdate, 1633522963509)
        XCTAssertEqual(dto.startedAt, 1600000000000)
        XCTAssertEqual(dto.finishedAt, 1700000000000)
    }

    func testToDTONilFinishedAtWhenNotFinished() {
        let mp = MediaProgress()
        mp.id = "li_3"
        mp.finishedAt = nil

        let dto = mp.toDTO()

        XCTAssertNil(dto.finishedAt)
    }

    func testRoundTripPreservesValues() {
        let original = Components.Schemas.mediaProgress(
            id: "li_4",
            userId: "u_4",
            libraryItemId: "li_4",
            episodeId: nil,
            duration: 100.25,
            progress: 0.33,
            currentTime: 33,
            isFinished: false,
            ebookLocation: nil,
            ebookProgress: nil,
            lastUpdate: 1000,
            startedAt: 2000,
            finishedAt: nil
        )

        let roundTripped = MediaProgress.from(dto: original).toDTO()

        XCTAssertEqual(roundTripped, original)
    }
}
