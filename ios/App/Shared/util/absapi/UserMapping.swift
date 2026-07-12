//
//  UserMapping.swift
//  Audiobookshelf
//
//  Phase 1 of the ABSApiClient migration. Bridges the generated Codable DTO
//  (Components.Schemas.userMinimal) to/from the Realm-backed User model.
//

import Foundation
import ABSApiClient

extension User {
    /// Build an *unmanaged* Realm User from the generated DTO.
    static func from(dto: Components.Schemas.userMinimal) -> User {
        let user = User()
        user.id = dto.id ?? ""
        user.username = dto.username ?? ""
        if let progresses = dto.mediaProgress {
            user.mediaProgress.append(objectsIn: progresses.map { MediaProgress.from(dto: $0) })
        }
        return user
    }

    /// Produce the generated DTO from this Realm User.
    func toDTO() -> Components.Schemas.userMinimal {
        Components.Schemas.userMinimal(
            id: id,
            username: username,
            mediaProgress: mediaProgress.map { $0.toDTO() }
        )
    }
}
