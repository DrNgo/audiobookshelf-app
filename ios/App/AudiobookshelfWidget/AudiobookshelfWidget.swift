//
//  AudiobookshelfWidget.swift
//  AudiobookshelfWidget
//
//  "Continue Listening" widget. Reads the server URL + token the app shares via the App Group,
//  fetches the user's top in-progress book and its playback progress directly from the server, and
//  renders it in the app's player style: cover-forward on a background derived from the cover's
//  average color (like AudioPlayer's coverRgb), with adaptive text contrast, a progress bar, elapsed
//  time, and interactive transport controls (iOS 17+). Tapping the body resumes via
//  audiobookshelf://resume.
//

import WidgetKit
import SwiftUI
import CoreImage

// MARK: - Model

struct AudiobookEntry: TimelineEntry {
    let date: Date
    let libraryItemId: String?
    let episodeId: String?
    let title: String
    let author: String?
    let cover: UIImage?
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let hasContent: Bool

    var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }

    /// Tap target: resume the exact item shown, so the app doesn't resume a stale loaded session.
    /// Falls back to the id-less link (most-recent in-progress) when we don't have an id.
    var resumeURL: URL? {
        guard let id = libraryItemId else { return URL(string: "audiobookshelf://resume") }
        var comps = URLComponents(string: "audiobookshelf://resume")
        var items = [URLQueryItem(name: "libraryItemId", value: id)]
        if let episodeId = episodeId { items.append(URLQueryItem(name: "episodeId", value: episodeId)) }
        comps?.queryItems = items
        return comps?.url
    }

    static func empty(_ message: String) -> AudiobookEntry {
        AudiobookEntry(date: Date(), libraryItemId: nil, episodeId: nil, title: message, author: nil, cover: nil, currentTime: 0, duration: 0, isPlaying: false, hasContent: false)
    }
    static let placeholder = AudiobookEntry(date: Date(), libraryItemId: nil, episodeId: nil, title: "Your Audiobook", author: "Author",
                                            cover: nil, currentTime: 1800, duration: 7200, isPlaying: false, hasContent: true)
}

// MARK: - Timeline

struct AudiobookProvider: TimelineProvider {
    func placeholder(in context: Context) -> AudiobookEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (AudiobookEntry) -> Void) {
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AudiobookEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    private func fetchEntry() async -> AudiobookEntry {
        guard let creds = WidgetSharedCredentials.load() else {
            return .empty("Open Audiobookshelf to sign in")
        }
        guard let item = await get("api/me/items-in-progress", creds, as: TopItem.self)?.libraryItems?.first,
              let id = item.id else {
            return .empty("Nothing in progress")
        }
        let progress = await get("api/me/progress/\(id)", creds, as: Progress.self)
        let cover = await loadCover(serverURL: creds.serverURL, token: creds.token, id: id)
        return AudiobookEntry(
            date: Date(),
            libraryItemId: id,
            episodeId: item.recentEpisode?.id,
            title: item.media?.metadata?.title ?? "Audiobook",
            author: item.media?.metadata?.authorName,
            cover: cover,
            currentTime: progress?.currentTime ?? 0,
            duration: progress?.duration ?? item.media?.duration ?? 0,
            isPlaying: WidgetSharedCredentials.isPlaying,
            hasContent: true
        )
    }

    private func get<T: Decodable>(_ path: String, _ creds: (serverURL: URL, token: String), as: T.Type) async -> T? {
        var req = URLRequest(url: creds.serverURL.appendingPathComponent(path))
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func loadCover(serverURL: URL, token: String, id: String) async -> UIImage? {
        var comps = URLComponents(url: serverURL.appendingPathComponent("api/items/\(id)/cover"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "format", value: "jpeg")]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return UIImage(data: data)
    }

    private struct TopItem: Decodable {
        let libraryItems: [Item]?
        struct Item: Decodable {
            let id: String?
            let media: Media?
            let recentEpisode: Episode?
            struct Media: Decodable {
                let duration: Double?
                let metadata: Meta?
                struct Meta: Decodable { let title: String?; let authorName: String? }
            }
            struct Episode: Decodable { let id: String? }
        }
    }
    private struct Progress: Decodable { let currentTime: Double?; let duration: Double? }
}

// MARK: - Helpers

private func prettyTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

/// A background color derived from the cover plus the matching text color (dark text on light
/// covers, light text on dark), mirroring the app player's coverRgb + coverBgIsLight.
private struct Palette {
    let background: Color
    let foreground: Color
    static let fallback = Palette(background: Color(red: 0.137, green: 0.137, blue: 0.137), foreground: .white)
}

private extension UIImage {
    var palette: Palette {
        guard let input = CIImage(image: self) else { return .fallback }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)
        ])
        guard let output = filter?.outputImage else { return .fallback }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return Palette(background: Color(red: r, green: g, blue: b), foreground: luminance > 0.62 ? .black : .white)
    }
}

// MARK: - Views

private struct CoverView: View {
    let cover: UIImage?
    let tint: Color
    var body: some View {
        Group {
            if let cover = cover {
                Image(uiImage: cover).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15))
                    .overlay(Image(systemName: "headphones").font(.title2).foregroundStyle(tint.opacity(0.6)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.25))
                Capsule().fill(tint).frame(width: max(3, geo.size.width * progress))
            }
        }
        .frame(height: 4)
    }
}

struct AudiobookshelfWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AudiobookProvider.Entry

    private var palette: Palette { entry.cover?.palette ?? .fallback }
    private var fg: Color { palette.foreground }

    var body: some View {
        content
            .widgetURL(entry.resumeURL)
            .widgetBackground(palette.background)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular: accessory
        case .systemSmall: small
        default: medium
        }
    }

    private var label: some View {
        Text("CONTINUE LISTENING")
            .font(.system(size: 10, weight: .bold)).tracking(0.6)
            .foregroundStyle(fg.opacity(0.7))
    }

    private var timeText: some View {
        HStack(spacing: 4) {
            Text(prettyTime(entry.currentTime))
            if entry.duration > 0 {
                Text("/").foregroundStyle(fg.opacity(0.4))
                Text(prettyTime(entry.duration))
            }
        }
        .font(.caption2).foregroundStyle(fg.opacity(0.75)).monospacedDigit()
    }

    // Home — small: glanceable, tap to resume
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(cover: entry.cover, tint: fg).frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.title).font(.footnote.weight(.semibold)).foregroundStyle(fg).lineLimit(2)
            if entry.hasContent { ProgressBar(progress: entry.progress, tint: fg) }
        }
    }

    // Home — medium: cover + details + transport, the player look
    private var medium: some View {
        HStack(spacing: 14) {
            CoverView(cover: entry.cover, tint: fg)
            VStack(alignment: .leading, spacing: 4) {
                label
                Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(fg).lineLimit(2)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(fg.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 2)
                if entry.hasContent {
                    ProgressBar(progress: entry.progress, tint: fg)
                    timeText
                    controls
                }
            }
            Spacer(minLength: 0)
        }
    }

    // Interactive transport (iOS 17+). Whole-widget tap still resumes; these drive the live session.
    @ViewBuilder private var controls: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 26) {
                Button(intent: WidgetSkipBackwardIntent()) { Image(systemName: "gobackward.10") }
                // Play/pause via the bridge — resumes/pauses the loaded session in place without
                // opening the app. (From a fully cold app, tap the widget body to open + resume.)
                Button(intent: WidgetPlayPauseIntent()) {
                    Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22))
                }
                Button(intent: WidgetSkipForwardIntent()) { Image(systemName: "goforward.10") }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(fg)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
    }

    // Lock screen — tinted monochrome (system handles color)
    private var accessory: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.caption.weight(.semibold)).lineLimit(1)
            if entry.hasContent {
                ProgressView(value: entry.progress).tint(.white)
                Text(prettyTime(entry.currentTime)).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(entry.author ?? "Audiobookshelf").font(.caption2)
            }
        }
    }
}

/// Cover-color background with a subtle top-to-bottom vignette for depth (so light covers still read
/// as an immersive player card, not a flat swatch). iOS 17+ uses containerBackground; plain on 16.
private extension View {
    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        let bg = ZStack {
            color
            LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        if #available(iOS 17.0, *) {
            self.padding(14).containerBackground(for: .widget) { bg }
        } else {
            self.padding(14).background(bg)
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
        .description("Resume and control your current audiobook.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct AudiobookshelfWidgetBundle: WidgetBundle {
    var body: some Widget {
        AudiobookshelfWidget()
    }
}
