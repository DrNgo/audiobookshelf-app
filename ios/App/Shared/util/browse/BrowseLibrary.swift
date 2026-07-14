//
//  BrowseLibrary.swift
//  App
//
//  A pure view model for one server book library, used by the CarPlay Library tab. Lenient decode
//  over GET /api/libraries; podcast libraries and entries missing id/name are dropped.
//

import Foundation

struct BrowseLibrary: Equatable {
    let id: String
    let name: String
}

extension BrowseLibrary {
    private struct Response: Decodable {
        let libraries: [Entry]?
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let mediaType: String?
        }
    }

    static func fromLibraries(data: Data) -> [BrowseLibrary] {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.libraries ?? []).compactMap { entry in
            guard entry.mediaType == "book",
                  let id = entry.id, !id.isEmpty,
                  let name = entry.name, !name.isEmpty else { return nil }
            return BrowseLibrary(id: id, name: name)
        }
    }
}
