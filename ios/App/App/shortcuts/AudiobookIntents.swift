//
//  AudiobookIntents.swift
//  App
//
//  Siri Shortcuts / App Intents (#725). Two intents — resume the most-recent in-progress book,
//  and play a book chosen (or spoken) by title — built on the shared Browse* layer that CarPlay
//  also uses. App Intents are discovered from the app binary (no extension), run in-process, and
//  drive PlayerHandler directly. Everything is iOS 16+; on iOS 14/15 the shortcuts simply don't
//  appear.
//

import AppIntents
import Foundation

// MARK: - Entity

@available(iOS 16.0, *)
struct AudiobookEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let author: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static var defaultQuery = AudiobookEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if let author = author, !author.isEmpty {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String, author: String?) {
        self.id = id
        self.title = title
        self.author = author
    }

    init(_ item: BrowseItem) {
        self.init(id: item.id, title: item.title, author: item.author)
    }

    /// A minimal server BrowseItem for playback (only id + isLocal are used by the starter).
    var browseItem: BrowseItem {
        BrowseItem(id: id, title: title, author: author, isLocal: false, coverURL: nil)
    }
}

@available(iOS 16.0, *)
struct AudiobookEntityQuery: EntityStringQuery {
    /// Resolve entities by id — best-effort from the in-progress suggestions (the only id-addressable
    /// set without another round-trip).
    func entities(for identifiers: [String]) async throws -> [AudiobookEntity] {
        let suggestions = try await suggestedEntities()
        return suggestions.filter { identifiers.contains($0.id) }
    }

    /// Free-text match — runs a library search (what Siri uses to resolve the spoken title).
    func entities(matching string: String) async throws -> [AudiobookEntity] {
        (await BrowseApi.search(query: string)).map(AudiobookEntity.init)
    }

    /// Default suggestions in the Shortcuts UI: the user's in-progress books.
    func suggestedEntities() async throws -> [AudiobookEntity] {
        (await BrowseApi.continueListening()).map(AudiobookEntity.init)
    }
}

// MARK: - Intents

@available(iOS 16.0, *)
struct ContinueListeningIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Continue Listening"
    static var description = IntentDescription("Resume your most recently played audiobook.")

    func perform() async throws -> some IntentResult {
        guard let item = (await BrowseApi.continueListening()).first else {
            throw AudiobookIntentError.nothingInProgress
        }
        await MainActor.run { BrowsePlaybackStarter.play(item) {} }
        return .result()
    }
}

@available(iOS 16.0, *)
struct PlayAudiobookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Audiobook"
    static var description = IntentDescription("Play an audiobook from your library.")

    @Parameter(title: "Audiobook")
    var audiobook: AudiobookEntity

    func perform() async throws -> some IntentResult {
        await MainActor.run { BrowsePlaybackStarter.play(audiobook.browseItem) {} }
        return .result()
    }
}

// MARK: - Shortcuts provider

@available(iOS 16.0, *)
struct AudiobookshelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)"
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayAudiobookIntent(),
            phrases: [
                "Play \(\.$audiobook) in \(.applicationName)"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "book.fill"
        )
    }
}

// MARK: - Errors

@available(iOS 16.0, *)
enum AudiobookIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case nothingInProgress

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingInProgress: return "You have no audiobooks in progress."
        }
    }
}
