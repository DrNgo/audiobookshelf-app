//
//  UserMappingTests.swift
//  AudiobookshelfUnitTests
//
//  Phase 1 of the ABSApiClient migration: verifies the DTO <-> Realm mapping for the
//  minimal user, including its nested media progress list.
//

import XCTest
import ABSApiClient
@testable import Audiobookshelf

final class UserMappingTests: XCTestCase {

    func testFromDTOMapsIdUsernameAndProgress() {
        let dto = Components.Schemas.userMinimal(
            id: "u_1",
            username: "root",
            mediaProgress: [
                Components.Schemas.mediaProgress(id: "li_1", libraryItemId: "li_1", currentTime: 10),
                Components.Schemas.mediaProgress(id: "li_2", libraryItemId: "li_2", currentTime: 20)
            ]
        )

        let user = User.from(dto: dto)

        XCTAssertEqual(user.id, "u_1")
        XCTAssertEqual(user.username, "root")
        XCTAssertEqual(user.mediaProgress.count, 2)
        XCTAssertEqual(user.mediaProgress[0].libraryItemId, "li_1")
        XCTAssertEqual(user.mediaProgress[0].currentTime, 10)
        XCTAssertEqual(user.mediaProgress[1].libraryItemId, "li_2")
        XCTAssertEqual(user.mediaProgress[1].currentTime, 20)
    }

    func testFromDTONilOptionalsUseDefaults() {
        let dto = Components.Schemas.userMinimal(id: "u_2")

        let user = User.from(dto: dto)

        XCTAssertEqual(user.id, "u_2")
        XCTAssertEqual(user.username, "")
        XCTAssertEqual(user.mediaProgress.count, 0)
    }

    func testToDTOMapsIdUsernameAndProgress() {
        let user = User()
        user.id = "u_3"
        user.username = "listener"
        let mp = MediaProgress()
        mp.id = "li_3"
        mp.libraryItemId = "li_3"
        mp.currentTime = 42
        user.mediaProgress.append(mp)

        let dto = user.toDTO()

        XCTAssertEqual(dto.id, "u_3")
        XCTAssertEqual(dto.username, "listener")
        XCTAssertEqual(dto.mediaProgress?.count, 1)
        XCTAssertEqual(dto.mediaProgress?.first?.libraryItemId, "li_3")
        XCTAssertEqual(dto.mediaProgress?.first?.currentTime, 42)
    }

    func testRoundTripPreservesValues() {
        // Non-optional-mapped fields (userId/duration/progress/currentTime/isFinished/
        // lastUpdate/startedAt) must be populated: a nil there round-trips to a Realm
        // default (0/false/""), which would not compare equal back to nil.
        let original = Components.Schemas.userMinimal(
            id: "u_4",
            username: "abc",
            mediaProgress: [
                Components.Schemas.mediaProgress(
                    id: "li_4",
                    userId: "u_4",
                    libraryItemId: "li_4",
                    duration: 100,
                    progress: 0.1,
                    currentTime: 5,
                    isFinished: false,
                    lastUpdate: 1000,
                    startedAt: 2000
                )
            ]
        )

        let roundTripped = User.from(dto: original).toDTO()

        XCTAssertEqual(roundTripped, original)
    }
}
