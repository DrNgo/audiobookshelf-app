//
//  AudiobookshelfWidget.swift
//  AudiobookshelfWidget
//
//  "Continue Listening" widget. Reads the server URL + token the app shares via the App Group,
//  fetches the user's top in-progress book directly from the server (one authenticated GET —
//  the widget only needs this single call and can't use the app's token-refresh, so linking the
//  full SDK here would add fragility for no gain), and renders it. Tapping opens the app and
//  resumes via the audiobookshelf://resume deep link.
//

import WidgetKit
import SwiftUI

// MARK: - Model

struct AudiobookEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
    let coverImage: Image?
    /// false → a "sign in / nothing in progress" placeholder state.
    let hasContent: Bool
}

// MARK: - Timeline

struct AudiobookProvider: TimelineProvider {
    func placeholder(in context: Context) -> AudiobookEntry {
        AudiobookEntry(date: Date(), title: "Your audiobook", author: "Author", coverImage: nil, hasContent: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (AudiobookEntry) -> Void) {
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AudiobookEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let next = Date().addingTimeInterval(30 * 60) // refresh ~every 30 min
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetchEntry() async -> AudiobookEntry {
        guard let creds = WidgetSharedCredentials.load() else {
            return AudiobookEntry(date: Date(), title: "Open Audiobookshelf to sign in", author: nil, coverImage: nil, hasContent: false)
        }
        guard let top = await fetchTopInProgress(serverURL: creds.serverURL, token: creds.token) else {
            return AudiobookEntry(date: Date(), title: "Nothing in progress", author: nil, coverImage: nil, hasContent: false)
        }
        let cover = await loadCover(serverURL: creds.serverURL, token: creds.token, id: top.id)
        return AudiobookEntry(date: Date(), title: top.title, author: top.author, coverImage: cover, hasContent: true)
    }

    private func fetchTopInProgress(serverURL: URL, token: String) async -> (id: String, title: String, author: String?)? {
        var req = URLRequest(url: serverURL.appendingPathComponent("api/me/items-in-progress"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }

        struct Response: Decodable {
            let libraryItems: [Item]?
            struct Item: Decodable {
                let id: String?
                let media: Media?
                struct Media: Decodable {
                    let metadata: Meta?
                    struct Meta: Decodable { let title: String?; let authorName: String? }
                }
            }
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              let item = resp.libraryItems?.first, let id = item.id else { return nil }
        return (id, item.media?.metadata?.title ?? "Audiobook", item.media?.metadata?.authorName)
    }

    private func loadCover(serverURL: URL, token: String, id: String) async -> Image? {
        var comps = URLComponents(url: serverURL.appendingPathComponent("api/items/\(id)/cover"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "format", value: "jpeg")]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req), let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
    }
}

// MARK: - View

struct AudiobookshelfWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AudiobookProvider.Entry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                accessory
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .widgetURL(URL(string: "audiobookshelf://resume"))
        .widgetContainerBackground()
    }

    private var header: some View {
        Text("CONTINUE LISTENING")
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private var cover: some View {
        Group {
            if let image = entry.coverImage {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            cover.frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.title).font(.footnote).fontWeight(.semibold).lineLimit(2)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            cover.frame(width: 92)
            VStack(alignment: .leading, spacing: 4) {
                header
                Text(entry.title).font(.headline).lineLimit(2)
                if let author = entry.author { Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                Label("Tap to resume", systemImage: "play.fill").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.hasContent ? "Continue Listening" : "Audiobookshelf").font(.caption2).fontWeight(.semibold)
            Text(entry.title).font(.caption).lineLimit(2)
        }
    }
}

/// containerBackground is required on iOS 17+; a no-op on 16.
private extension View {
    @ViewBuilder func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.padding().containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
        }
    }
}

// MARK: - Widget

struct AudiobookshelfWidget: Widget {
    let kind = "AudiobookshelfWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AudiobookProvider()) { entry in
            AudiobookshelfWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Continue Listening")
        .description("Resume your current audiobook.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct AudiobookshelfWidgetBundle: WidgetBundle {
    var body: some Widget {
        AudiobookshelfWidget()
    }
}
