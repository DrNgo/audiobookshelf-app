//
//  AudiobookshelfWidget.swift
//  AudiobookshelfWidget
//
//  Home/lock-screen widget (#541 roadmap). Placeholder scaffold — real data (SDK fetch of the
//  in-progress book via shared App Group credentials) and the interactive Resume button are wired
//  in once the target builds and embeds cleanly.
//

import WidgetKit
import SwiftUI

struct AudiobookEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String?
}

struct AudiobookProvider: TimelineProvider {
    func placeholder(in context: Context) -> AudiobookEntry {
        AudiobookEntry(date: Date(), title: "Audiobook", author: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (AudiobookEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AudiobookEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct AudiobookshelfWidgetEntryView: View {
    var entry: AudiobookProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Continue Listening").font(.caption2).foregroundStyle(.secondary)
            Text(entry.title).font(.headline).lineLimit(2)
            if let author = entry.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding()
    }
}

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
