# Read-While-Listening Captions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a listener read along with a downloaded audiobook, using on-device speech recognition that runs ahead of the playhead and highlights the current word in sync with the audio.

**Architecture:** A pure-Swift timeline/store/scheduler stack in `ios/App/Shared/util/captions/` (fully unit-testable, no iOS 26 symbols), an iOS 26-gated `SpeechTranscriber` engine behind a `SegmentProducing` protocol, a thin `AbsTranscriber` Capacitor plugin, and a Vue caption panel that interpolates a smooth clock between the player's 1-second time polls.

**Tech Stack:** Swift 5, RealmSwift, Capacitor 7, Speech framework (`SpeechAnalyzer`/`SpeechTranscriber`, iOS 26+), AVFoundation, Vue 2 / Nuxt 2, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-22-read-while-listening-captions-design.md`

## Global Constraints

- **iOS 26.0+ only.** Every `SpeechAnalyzer`/`SpeechTranscriber` symbol sits behind `@available(iOS 26.0, *)`. The project deployment target stays at 14.0 — do not raise it.
- **Exactly one availability gate.** Only `AbsTranscriber.swift` may contain `if #available(iOS 26.0, *)`. Timeline, store, and scheduler must compile and test without any iOS 26 symbol.
- **No new dependencies.** No SPM packages, no pods, no npm packages. Speech is a system framework.
- **Swift source layout:** pure logic in `ios/App/Shared/util/captions/`, plugin in `ios/App/App/plugins/`. Tests mirror source at `ios/App/AudiobookshelfUnitTests/Shared/util/captions/`.
- **Test module import:** `@testable import Audiobookshelf`.
- **Audiobooks only.** Never touch `LocalPodcastEpisode`.
- **Volatile results are disabled.** Only finalized transcription results are ever emitted.
- **Content scope:** downloaded books only. Never attempt transcription against a streaming URL.

### Procedure A — Registering a new Swift file with the Xcode targets

Every new Swift file must be added to a target or it will not compile, and tests will fail with "cannot find X in scope".

**Target names vs the scheme:** the shared *scheme* is `App`, but the native *targets* are named `Audiobookshelf`, `AudiobookshelfWidget`, and `AudiobookshelfUnitTests` — there is no target literally named `App` (verify with `ruby -e 'require "xcodeproj"; p Xcodeproj::Project.open("ios/App/App.xcodeproj").targets.map(&:name)'`). App sources go in the **`Audiobookshelf`** target; test files go in **`AudiobookshelfUnitTests`**. `xcodebuild` still uses `-scheme App`.

```bash
cd /Users/michaelngo/projects/audiobookshelf-app/ios/App
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("App.xcodeproj")
# args: <path relative to ios/App> <target name>
path, target_name = ARGV
target = proj.targets.find { |t| t.name == target_name }
group = proj.main_group
path.split("/")[0..-2].each do |part|
  group = group.find_subpath(part, true)
end
ref = group.new_reference(File.expand_path(path))
target.add_file_references([ref])
proj.save
' <RELATIVE_PATH> <TARGET_NAME>
```

If the `xcodeproj` gem is missing: `gem install xcodeproj`. Adding the file through the Xcode GUI is equally valid.

### Procedure B — Committing `project.pbxproj`

`ios/App/App.xcodeproj/project.pbxproj` is marked `assume-unchanged` in this repo to hide local signing overrides. A plain `git add` will silently no-op or leak your `DEVELOPMENT_TEAM`.

**Whenever a task modifies `project.pbxproj`, invoke the `commit-xcodeproj-changes` skill and follow it.** Do not improvise this.

### Running the unit tests

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild test -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AudiobookshelfUnitTests/<TestClassName> 2>&1 | tail -30
```

If `iPhone 16` is not an available simulator, run `xcrun simctl list devices available` and substitute a booted iOS device name.

---

## File Structure

**Create:**
- `ios/App/Shared/util/captions/CaptionModels.swift` — `CaptionWord`, `CaptionSegment`, `CaptionTrack`, `TrackPlacement`, `TranscriptionRequest`
- `ios/App/Shared/util/captions/CaptionTimeline.swift` — pure book-time ↔ track math, gap/window arithmetic
- `ios/App/Shared/util/captions/CaptionStore.swift` — `captions.json` persistence with locale/version invalidation
- `ios/App/Shared/util/captions/SegmentProducing.swift` — the protocol the scheduler depends on
- `ios/App/Shared/util/captions/CaptionScheduler.swift` — sliding-window orchestration
- `ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift` — iOS 26 `SpeechTranscriber` implementation
- `ios/App/App/plugins/AbsTranscriber.swift` — Capacitor surface
- `plugins/capacitor/AbsTranscriber.js` — JS wrapper
- `utils/captionClock.js` — pure clock/lookup math
- `components/player/CaptionPanel.vue` — caption rendering
- Test files mirroring each pure unit

**Modify:**
- `ios/App/App/Info.plist` — add `NSSpeechRecognitionUsageDescription`
- `plugins/capacitor/index.js` — export `AbsTranscriber`
- `components/app/AudioPlayer.vue:33-41` — CC toggle and conditional cover/caption swap

---

### Task 1: Caption models and book-time → track mapping

**Files:**
- Create: `ios/App/Shared/util/captions/CaptionModels.swift`
- Create: `ios/App/Shared/util/captions/CaptionTimeline.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `CaptionWord(start:end:text:)`, `CaptionSegment(start:end:text:words:)`, `CaptionTrack(index:startOffset:duration:localFileId:)`, `TrackPlacement(track:offsetInTrack:)`, `CaptionTimeline.placement(forBookTime:tracks:) -> TrackPlacement?`. All times are `Double` seconds. Segment and word times are always **book-global**, never file-relative.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift`:

```swift
//
//  CaptionTimelineTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionTimelineTests: XCTestCase {

    // A three-track book: 0-100, 100-250, 250-400 (book seconds).
    private let tracks = [
        CaptionTrack(index: 0, startOffset: 0, duration: 100, localFileId: "f0"),
        CaptionTrack(index: 1, startOffset: 100, duration: 150, localFileId: "f1"),
        CaptionTrack(index: 2, startOffset: 250, duration: 150, localFileId: "f2"),
    ]

    func testPlacementInFirstTrack() {
        let p = CaptionTimeline.placement(forBookTime: 42, tracks: tracks)
        XCTAssertEqual(p?.track.index, 0)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 42, accuracy: 0.001)
    }

    func testPlacementInMiddleTrackSubtractsStartOffset() {
        let p = CaptionTimeline.placement(forBookTime: 160, tracks: tracks)
        XCTAssertEqual(p?.track.index, 1)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 60, accuracy: 0.001)
    }

    // A boundary time belongs to the track it starts, not the one it ends.
    func testExactBoundaryBelongsToLaterTrack() {
        let p = CaptionTimeline.placement(forBookTime: 100, tracks: tracks)
        XCTAssertEqual(p?.track.index, 1)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 0, accuracy: 0.001)
    }

    func testTimeBeyondLastTrackReturnsNil() {
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 400, tracks: tracks))
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 9999, tracks: tracks))
    }

    func testNegativeTimeClampsToFirstTrack() {
        let p = CaptionTimeline.placement(forBookTime: -5, tracks: tracks)
        XCTAssertEqual(p?.track.index, 0)
        XCTAssertEqual(p?.offsetInTrack ?? -1, 0, accuracy: 0.001)
    }

    func testEmptyTrackListReturnsNil() {
        XCTAssertNil(CaptionTimeline.placement(forBookTime: 10, tracks: []))
    }
}
```

- [ ] **Step 2: Register the test file with the test target**

Follow **Procedure A** with `AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift` and target `AudiobookshelfUnitTests`.

- [ ] **Step 3: Run the test to verify it fails**

Run the test command from Global Constraints with `-only-testing:AudiobookshelfUnitTests/CaptionTimelineTests`.
Expected: compile failure, "cannot find 'CaptionTrack' in scope".

- [ ] **Step 4: Write the models**

Create `ios/App/Shared/util/captions/CaptionModels.swift`:

```swift
//
//  CaptionModels.swift
//  Audiobookshelf
//
//  Value types shared by the caption timeline, store, scheduler, and engine.
//  Every time in these types is book-global seconds unless the name says otherwise.
//

import Foundation

struct CaptionWord: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct CaptionSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let words: [CaptionWord]
}

/// A downloaded audio track, flattened out of Realm so the timeline stays testable.
struct CaptionTrack: Equatable {
    let index: Int
    let startOffset: Double
    let duration: Double
    let localFileId: String

    var endOffset: Double { startOffset + duration }
}

struct TrackPlacement: Equatable {
    let track: CaptionTrack
    /// Seconds from the start of this track's file.
    let offsetInTrack: Double
}
```

- [ ] **Step 5: Write the timeline mapping**

Create `ios/App/Shared/util/captions/CaptionTimeline.swift`:

```swift
//
//  CaptionTimeline.swift
//  Audiobookshelf
//
//  Pure arithmetic mapping book-global time onto downloaded track files.
//  No Realm, no Speech, no I/O — this is the unit that carries the real bugs.
//

import Foundation

enum CaptionTimeline {

    /// Locate a book-global time within the track list.
    /// A time exactly on a boundary belongs to the track it *starts*.
    /// Returns nil past the end of the last track, or for an empty list.
    static func placement(forBookTime bookTime: Double, tracks: [CaptionTrack]) -> TrackPlacement? {
        guard !tracks.isEmpty else { return nil }
        let sorted = tracks.sorted { $0.startOffset < $1.startOffset }
        let clamped = max(bookTime, sorted[0].startOffset)

        guard let track = sorted.last(where: { $0.startOffset <= clamped }) else { return nil }
        guard clamped < track.endOffset else { return nil }

        return TrackPlacement(track: track, offsetInTrack: clamped - track.startOffset)
    }
}
```

- [ ] **Step 6: Register both source files with the App target**

Follow **Procedure A** twice, with target `Audiobookshelf`:
- `Shared/util/captions/CaptionModels.swift`
- `Shared/util/captions/CaptionTimeline.swift`

- [ ] **Step 7: Run the test to verify it passes**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionTimelineTests`.
Expected: `** TEST SUCCEEDED **`, 6 tests passing.

- [ ] **Step 8: Commit**

The pbxproj changed, so use **Procedure B** — invoke the `commit-xcodeproj-changes` skill. The commit should include:

```
ios/App/Shared/util/captions/CaptionModels.swift
ios/App/Shared/util/captions/CaptionTimeline.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift
ios/App/App.xcodeproj/project.pbxproj
```

Message: `feat(ios): caption models and book-time to track mapping`

---

### Task 2: Gap detection and transcription window arithmetic

**Files:**
- Modify: `ios/App/Shared/util/captions/CaptionModels.swift` (add `TranscriptionRequest`)
- Modify: `ios/App/Shared/util/captions/CaptionTimeline.swift` (add gap functions)
- Modify: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift`

**Interfaces:**
- Consumes: `CaptionSegment`, `CaptionTrack`, `TrackPlacement`, `CaptionTimeline.placement(forBookTime:tracks:)` from Task 1
- Produces: `TranscriptionRequest(localFileId:offsetInTrack:duration:bookOffset:)`, `CaptionTimeline.coveredUntil(from:segments:) -> Double`, `CaptionTimeline.nextRequest(playhead:segments:tracks:windowAhead:) -> TranscriptionRequest?`

- [ ] **Step 1: Write the failing tests**

Append to `CaptionTimelineTests.swift` (inside the existing class):

```swift
    private func seg(_ start: Double, _ end: Double) -> CaptionSegment {
        CaptionSegment(start: start, end: end, text: "x",
                       words: [CaptionWord(start: start, end: end, text: "x")])
    }

    // MARK: coveredUntil

    func testCoveredUntilReturnsPlayheadWhenNothingCovers() {
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 50, segments: [seg(200, 210)]), 50, accuracy: 0.001)
    }

    func testCoveredUntilFollowsContiguousRun() {
        let segs = [seg(40, 50), seg(50, 60), seg(60, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    // A gap larger than the join tolerance stops the run.
    func testCoveredUntilStopsAtGap() {
        let segs = [seg(40, 50), seg(58, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 50, accuracy: 0.001)
    }

    // Sub-second silences between segments are normal speech, not gaps.
    func testCoveredUntilToleratesSmallGaps() {
        let segs = [seg(40, 50), seg(50.4, 70)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    func testCoveredUntilHandlesUnsortedSegments() {
        let segs = [seg(60, 70), seg(40, 50), seg(50, 60)]
        XCTAssertEqual(CaptionTimeline.coveredUntil(from: 45, segments: segs), 70, accuracy: 0.001)
    }

    // MARK: nextRequest

    func testNextRequestFillsFromPlayheadWhenNothingCached() {
        let r = CaptionTimeline.nextRequest(playhead: 10, segments: [], tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.localFileId, "f0")
        XCTAssertEqual(r?.offsetInTrack ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(r?.bookOffset ?? -1, 10, accuracy: 0.001)
        // Clipped to the end of track 0 (100s), not the full 600s window.
        XCTAssertEqual(r?.duration ?? -1, 90, accuracy: 0.001)
    }

    // The request must never span two files — the engine reads one file at a time.
    func testNextRequestIsClippedToTrackBoundary() {
        let r = CaptionTimeline.nextRequest(playhead: 240, segments: [], tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.localFileId, "f1")
        XCTAssertEqual(r?.offsetInTrack ?? -1, 140, accuracy: 0.001)
        XCTAssertEqual(r?.duration ?? -1, 10, accuracy: 0.001)
    }

    func testNextRequestResumesAfterCachedCoverage() {
        let segs = [seg(10, 20), seg(20, 30)]
        let r = CaptionTimeline.nextRequest(playhead: 10, segments: segs, tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.bookOffset ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(r?.offsetInTrack ?? -1, 30, accuracy: 0.001)
    }

    func testNextRequestReturnsNilWhenWindowIsFull() {
        let segs = [seg(10, 700)]
        XCTAssertNil(CaptionTimeline.nextRequest(playhead: 10, segments: segs, tracks: tracks, windowAhead: 600))
    }

    func testNextRequestReturnsNilPastEndOfBook() {
        XCTAssertNil(CaptionTimeline.nextRequest(playhead: 400, segments: [], tracks: tracks, windowAhead: 600))
    }

    // A negative playhead must clamp to the first track, not over-read it.
    func testNextRequestClampsNegativePlayhead() {
        let r = CaptionTimeline.nextRequest(playhead: -50, segments: [], tracks: tracks, windowAhead: 600)
        XCTAssertEqual(r?.localFileId, "f0")
        XCTAssertEqual(r?.offsetInTrack ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(r?.bookOffset ?? -1, 0, accuracy: 0.001)
        // Must not exceed the 100s track even though the window is 600s.
        XCTAssertEqual(r?.duration ?? -1, 100, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionTimelineTests`.
Expected: compile failure, "type 'CaptionTimeline' has no member 'coveredUntil'".

- [ ] **Step 3: Add `TranscriptionRequest` to the models**

Append to `ios/App/Shared/util/captions/CaptionModels.swift`:

```swift
/// One contiguous unit of work for the engine. Never spans more than one file.
struct TranscriptionRequest: Equatable {
    let localFileId: String
    /// Seconds from the start of the file to begin reading.
    let offsetInTrack: Double
    /// Seconds of audio to read.
    let duration: Double
    /// The book-global time corresponding to `offsetInTrack`, used to shift
    /// file-relative recognizer timings back into book time.
    let bookOffset: Double
}
```

- [ ] **Step 4: Implement the gap arithmetic**

Append inside `enum CaptionTimeline` in `ios/App/Shared/util/captions/CaptionTimeline.swift`:

```swift
    /// Segments separated by less than this are treated as one contiguous run.
    /// Ordinary sentence pauses in narration land well under half a second.
    static let joinTolerance: Double = 0.5

    /// Walk forward from `playhead` through contiguous segment coverage and
    /// return the book time where that coverage runs out.
    static func coveredUntil(from playhead: Double, segments: [CaptionSegment]) -> Double {
        let sorted = segments.sorted { $0.start < $1.start }
        var frontier = playhead
        for segment in sorted {
            if segment.end <= frontier { continue }
            guard segment.start <= frontier + joinTolerance else { break }
            frontier = segment.end
        }
        return frontier
    }

    /// The next unit of work needed to keep `windowAhead` seconds decoded past
    /// the playhead, or nil if the window is already full or the book has ended.
    static func nextRequest(playhead: Double,
                            segments: [CaptionSegment],
                            tracks: [CaptionTrack],
                            windowAhead: Double) -> TranscriptionRequest? {
        guard !tracks.isEmpty else { return nil }
        // Clamp to the earliest track start so a negative/pre-start playhead
        // can't produce a negative frontier (which would over-read the track,
        // emit negative book times, and re-request the same region forever).
        let firstStart = tracks.map(\.startOffset).min() ?? 0
        let clampedPlayhead = max(playhead, firstStart)

        let frontier = coveredUntil(from: clampedPlayhead, segments: segments)
        let target = clampedPlayhead + windowAhead
        guard frontier < target else { return nil }
        guard let placement = placement(forBookTime: frontier, tracks: tracks) else { return nil }

        // Remaining audio in THIS track's file, from the placement's own offset —
        // one request never spans two files. Equal to endOffset - frontier when
        // unclamped, but correct even when the playhead was clamped.
        let remainingInTrack = placement.track.duration - placement.offsetInTrack
        let duration = min(target - frontier, remainingInTrack)
        guard duration > 0 else { return nil }

        return TranscriptionRequest(localFileId: placement.track.localFileId,
                                    offsetInTrack: placement.offsetInTrack,
                                    duration: duration,
                                    bookOffset: frontier)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionTimelineTests`.
Expected: `** TEST SUCCEEDED **`, 16 tests passing.

- [ ] **Step 6: Commit**

```bash
git add ios/App/Shared/util/captions/CaptionModels.swift \
        ios/App/Shared/util/captions/CaptionTimeline.swift \
        ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionTimelineTests.swift
git commit -m "feat(ios): caption gap detection and window arithmetic"
```

---

### Task 3: Caption persistence with locale and version invalidation

**Files:**
- Create: `ios/App/Shared/util/captions/CaptionStore.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionStoreTests.swift`

**Interfaces:**
- Consumes: `CaptionSegment` from Task 1
- Produces: `CaptionStore(directory: URL)`, `store.load(locale: String) -> [CaptionSegment]`, `store.append(_ segments: [CaptionSegment], locale: String) throws`, `store.evict()`. `load` returns `[]` on any mismatch, corruption, or missing file — it never throws.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionStoreTests.swift`:

```swift
//
//  CaptionStoreTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captions-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func seg(_ start: Double, _ end: Double, _ text: String) -> CaptionSegment {
        CaptionSegment(start: start, end: end, text: text,
                       words: [CaptionWord(start: start, end: end, text: text)])
    }

    func testLoadOnMissingFileReturnsEmpty() {
        let store = CaptionStore(directory: dir)
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testAppendThenLoadRoundTrips() throws {
        let store = CaptionStore(directory: dir)
        let segs = [seg(0, 1, "hello"), seg(1, 2, "world")]
        try store.append(segs, locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US"), segs)
    }

    func testAppendAccumulatesAndSortsByStart() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(10, 11, "b")], locale: "en-US")
        try store.append([seg(0, 1, "a")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US").map(\.text), ["a", "b"])
    }

    // Re-transcribing the same region must not duplicate it.
    func testAppendDeduplicatesIdenticalStarts() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(5, 6, "once")], locale: "en-US")
        try store.append([seg(5, 6, "once")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "en-US").count, 1)
    }

    // A device language change must not silently serve mismatched text.
    func testLoadWithDifferentLocaleReturnsEmpty() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        XCTAssertEqual(store.load(locale: "de-DE"), [])
    }

    func testAppendAfterLocaleChangeReplacesCache() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        try store.append([seg(0, 1, "hallo")], locale: "de-DE")
        XCTAssertEqual(store.load(locale: "de-DE").map(\.text), ["hallo"])
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testCorruptFileReturnsEmptyInsteadOfThrowing() throws {
        let store = CaptionStore(directory: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("captions.json"))
        XCTAssertEqual(store.load(locale: "en-US"), [])
    }

    func testEvictRemovesTheFile() throws {
        let store = CaptionStore(directory: dir)
        try store.append([seg(0, 1, "hello")], locale: "en-US")
        store.evict()
        XCTAssertEqual(store.load(locale: "en-US"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("captions.json").path))
    }
}
```

- [ ] **Step 2: Register the test file**

Follow **Procedure A** with `AudiobookshelfUnitTests/Shared/util/captions/CaptionStoreTests.swift` and target `AudiobookshelfUnitTests`.

- [ ] **Step 3: Run the test to verify it fails**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionStoreTests`.
Expected: compile failure, "cannot find 'CaptionStore' in scope".

- [ ] **Step 4: Implement the store**

Create `ios/App/Shared/util/captions/CaptionStore.swift`:

```swift
//
//  CaptionStore.swift
//  Audiobookshelf
//
//  Persists caption segments as a single JSON file inside the item's existing
//  download folder, so deleting a download deletes its captions for free.
//

import Foundation

final class CaptionStore {

    private static let schemaVersion = 1
    private static let filename = "captions.json"

    private struct Payload: Codable {
        let version: Int
        let locale: String
        let segments: [CaptionSegment]
    }

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Cached segments for `locale`, or `[]` when absent, stale, or unreadable.
    /// Never throws — a broken cache degrades to re-transcription, not a crash.
    func load(locale: String) -> [CaptionSegment] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.schemaVersion,
              payload.locale == locale
        else { return [] }
        return payload.segments
    }

    /// Merge `segments` into the cache. A locale change discards the old cache
    /// rather than mixing languages.
    func append(_ segments: [CaptionSegment], locale: String) throws {
        var merged = load(locale: locale)

        var seenStarts = Set(merged.map { Self.key($0.start) })
        for segment in segments where !seenStarts.contains(Self.key(segment.start)) {
            seenStarts.insert(Self.key(segment.start))
            merged.append(segment)
        }
        merged.sort { $0.start < $1.start }

        let payload = Payload(version: Self.schemaVersion, locale: locale, segments: merged)
        let data = try JSONEncoder().encode(payload)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    func evict() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Millisecond-quantised start time, so float noise can't defeat dedup.
    private static func key(_ time: Double) -> Int {
        Int((time * 1000).rounded())
    }
}
```

- [ ] **Step 5: Register the source file with the App target**

Follow **Procedure A** with `Shared/util/captions/CaptionStore.swift` and target `Audiobookshelf`.

- [ ] **Step 6: Run the tests to verify they pass**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionStoreTests`.
Expected: `** TEST SUCCEEDED **`, 8 tests passing.

- [ ] **Step 7: Commit**

The pbxproj changed — use **Procedure B** (`commit-xcodeproj-changes` skill), including:

```
ios/App/Shared/util/captions/CaptionStore.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionStoreTests.swift
ios/App/App.xcodeproj/project.pbxproj
```

Message: `feat(ios): caption cache with locale and schema invalidation`

---

### Task 4: The sliding-window scheduler

**Files:**
- Create: `ios/App/Shared/util/captions/SegmentProducing.swift`
- Create: `ios/App/Shared/util/captions/CaptionScheduler.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionSchedulerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3
- Produces:
  - `protocol SegmentProducing { func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> }`
  - `actor CaptionScheduler` with `init(tracks:fileURLs:store:engine:locale:windowAhead:refillMargin:onSegments:)`, `func start(at bookTime: Double) async`, `func seek(to bookTime: Double) async`, `func stop()`
- `fileURLs` is `[String: URL]` keyed by `localFileId`. `onSegments` is `@Sendable ([CaptionSegment]) -> Void`, invoked for cached and freshly-produced segments alike.

- [ ] **Step 1: Write the protocol**

Create `ios/App/Shared/util/captions/SegmentProducing.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing test**

> **Swift gotcha:** `XCTAssertEqual`/`XCTAssertGreaterThan` take a non-`async` `@autoclosure`, so `await` cannot appear inside their arguments (e.g. `XCTAssertEqual(await engine.callCount(), 1)` won't compile). Hoist each awaited value into a preceding `let` first — `let count = await engine.callCount(); XCTAssertEqual(count, 1)` — at every such site below. Semantics are unchanged.

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionSchedulerTests.swift`:

```swift
//
//  CaptionSchedulerTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

/// Records every request it receives and emits one segment covering the whole span.
private actor FakeEngine: SegmentProducing {
    private var recorded: [TranscriptionRequest] = []

    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                let segment = CaptionSegment(
                    start: request.bookOffset,
                    end: request.bookOffset + request.duration,
                    text: "seg@\(Int(request.bookOffset))",
                    words: [CaptionWord(start: request.bookOffset,
                                        end: request.bookOffset + request.duration,
                                        text: "seg")]
                )
                continuation.yield(segment)
                continuation.finish()
            }
        }
    }

    private func record(_ r: TranscriptionRequest) { recorded.append(r) }
    func recordedRequests() -> [TranscriptionRequest] { recorded }
}

private actor FailingEngine: SegmentProducing {
    struct Boom: Error {}
    private var calls = 0
    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.bump()
                continuation.finish(throwing: Boom())
            }
        }
    }
    private func bump() { calls += 1 }
    func callCount() -> Int { calls }
}

final class CaptionSchedulerTests: XCTestCase {

    private var dir: URL!

    private let tracks = [
        CaptionTrack(index: 0, startOffset: 0, duration: 100, localFileId: "f0"),
        CaptionTrack(index: 1, startOffset: 100, duration: 150, localFileId: "f1"),
    ]

    private var fileURLs: [String: URL] {
        ["f0": dir.appendingPathComponent("f0.m4b"),
         "f1": dir.appendingPathComponent("f1.m4b")]
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeScheduler(engine: SegmentProducing,
                               store: CaptionStore? = nil,
                               windowAhead: Double = 60,
                               onSegments: @escaping @Sendable ([CaptionSegment]) -> Void = { _ in }) -> CaptionScheduler {
        CaptionScheduler(tracks: tracks,
                         fileURLs: fileURLs,
                         store: store ?? CaptionStore(directory: dir),
                         engine: engine,
                         locale: "en-US",
                         windowAhead: windowAhead,
                         refillMargin: 30,
                         onSegments: onSegments)
    }

    func testStartFillsTheWindowFromThePlayhead() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.first?.bookOffset ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(requests.first?.localFileId, "f0")
    }

    func testSchedulerStopsOnceWindowIsFull() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        // One 60s request fills a 60s window; it must not keep requesting.
        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRequestsChainAcrossATrackBoundary() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 120)
        await scheduler.start(at: 40)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].localFileId, "f0")
        XCTAssertEqual(requests[0].duration, 60, accuracy: 0.001)
        XCTAssertEqual(requests[1].localFileId, "f1")
        XCTAssertEqual(requests[1].offsetInTrack, 0, accuracy: 0.001)
    }

    func testCachedSegmentsAreEmittedWithoutCallingTheEngine() async throws {
        let store = CaptionStore(directory: dir)
        try store.append([CaptionSegment(start: 0, end: 90, text: "cached",
                                         words: [CaptionWord(start: 0, end: 90, text: "cached")])],
                         locale: "en-US")

        let engine = FakeEngine()
        let box = SegmentBox()
        let scheduler = makeScheduler(engine: engine, store: store, windowAhead: 60) { segs in
            box.append(segs)
        }
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        XCTAssertEqual(await engine.recordedRequests().count, 0)
        XCTAssertEqual(box.all().map(\.text), ["cached"])
    }

    func testProducedSegmentsArePersisted() async {
        let store = CaptionStore(directory: dir)
        let scheduler = makeScheduler(engine: FakeEngine(), store: store, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        XCTAssertFalse(store.load(locale: "en-US").isEmpty)
    }

    func testSeekBackwardIntoCachedAudioMakesNoNewRequests() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.seek(to: 10)
        await scheduler.drainForTesting()

        XCTAssertEqual(await engine.recordedRequests().count, afterStart)
    }

    func testSeekForwardRequestsTheNewRegion() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()

        await scheduler.seek(to: 200)
        await scheduler.drainForTesting()

        let requests = await engine.recordedRequests()
        XCTAssertTrue(requests.contains { abs($0.bookOffset - 200) < 0.001 })
    }

    func testStopPreventsFurtherRequests() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.stop()
        await scheduler.advance(to: 400)
        await scheduler.drainForTesting()

        XCTAssertEqual(await engine.recordedRequests().count, afterStart,
                       "a stopped scheduler must issue no work when the playhead advances")
    }

    func testSuspendStopsWorkAndResumeRestartsIt() async {
        let engine = FakeEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        let afterStart = await engine.recordedRequests().count

        await scheduler.suspend()
        await scheduler.advance(to: 55)
        await scheduler.drainForTesting()
        XCTAssertEqual(await engine.recordedRequests().count, afterStart,
                       "a suspended scheduler must not transcribe in the background")

        await scheduler.resume()
        await scheduler.drainForTesting()
        XCTAssertGreaterThan(await engine.recordedRequests().count, afterStart,
                             "resuming must top the window back up")
    }

    // An engine failure must not wedge the scheduler, crash playback, or
    // retry the same failing gap forever.
    func testEngineFailureIsSwallowedAndNotRetried() async {
        let engine = FailingEngine()
        let scheduler = makeScheduler(engine: engine, windowAhead: 60)
        await scheduler.start(at: 0)
        await scheduler.drainForTesting()
        XCTAssertEqual(await engine.callCount(), 1,
                       "a failed gap must be attempted once, not retried in a loop")

        // Advancing within the same still-failed region must not re-attempt it.
        await scheduler.advance(to: 5)
        await scheduler.drainForTesting()
        XCTAssertEqual(await engine.callCount(), 1,
                       "advancing over a known-failed gap must not re-request it")

        // A seek is a fresh chance — the failed offset set is cleared.
        await scheduler.seek(to: 0)
        await scheduler.drainForTesting()
        XCTAssertEqual(await engine.callCount(), 2, "a seek should retry the failed region once")
    }
}

/// Thread-safe collector for the onSegments callback.
private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [CaptionSegment] = []
    func append(_ s: [CaptionSegment]) { lock.lock(); segments += s; lock.unlock() }
    func all() -> [CaptionSegment] { lock.lock(); defer { lock.unlock() }; return segments }
}
```

- [ ] **Step 3: Register the test file**

Follow **Procedure A** with `AudiobookshelfUnitTests/Shared/util/captions/CaptionSchedulerTests.swift` and target `AudiobookshelfUnitTests`.

- [ ] **Step 4: Run the test to verify it fails**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionSchedulerTests`.
Expected: compile failure, "cannot find 'CaptionScheduler' in scope".

- [ ] **Step 5: Implement the scheduler**

Create `ios/App/Shared/util/captions/CaptionScheduler.swift`:

```swift
//
//  CaptionScheduler.swift
//  Audiobookshelf
//
//  Keeps a window of transcribed audio ahead of the playhead. Exactly one engine
//  job runs at a time; once the window is full the scheduler idles at zero CPU.
//

import Foundation

actor CaptionScheduler {

    private let tracks: [CaptionTrack]
    private let fileURLs: [String: URL]
    private let store: CaptionStore
    private let engine: SegmentProducing
    private let locale: String
    private let windowAhead: Double
    private let refillMargin: Double
    private let onSegments: @Sendable ([CaptionSegment]) -> Void
    private let logger = AppLogger(category: "CaptionScheduler")

    private var segments: [CaptionSegment] = []
    private var playhead: Double = 0
    private var isRunning = false
    private var isSuspended = false
    private var isFilling = false
    private var fillTask: Task<Void, Never>?
    /// Bumped whenever in-flight work is superseded (seek/stop/suspend). A fill
    /// task compares its captured generation against this on completion and does
    /// nothing if it was superseded — this is what makes a stale task's return
    /// harmless instead of letting it clobber the newer task's handle.
    private var generation = 0
    /// Book-time ranges the engine failed on. A failed gap is dammed (not
    /// re-requested) until a seek clears it. Range-keyed, NOT point-keyed: a
    /// request's bookOffset advances with the playhead while a gap stays
    /// uncovered (coveredUntil echoes the playhead back), so a point key would
    /// fail to suppress the repeat and re-request the failed region on every
    /// advance. Naturally escaped once the playhead advances past the range.
    private var failedRanges: [Range<Double>] = []

    init(tracks: [CaptionTrack],
         fileURLs: [String: URL],
         store: CaptionStore,
         engine: SegmentProducing,
         locale: String,
         windowAhead: Double = 600,
         refillMargin: Double = 300,
         onSegments: @escaping @Sendable ([CaptionSegment]) -> Void) {
        self.tracks = tracks
        self.fileURLs = fileURLs
        self.store = store
        self.engine = engine
        self.locale = locale
        self.windowAhead = windowAhead
        self.refillMargin = refillMargin
        self.onSegments = onSegments
    }

    func start(at bookTime: Double) {
        isRunning = true
        playhead = bookTime

        // Serve the cache first so captions paint immediately.
        segments = store.load(locale: locale)
        if !segments.isEmpty {
            onSegments(segments)
        }
        scheduleFillIfNeeded()
    }

    func seek(to bookTime: Double) {
        playhead = bookTime
        // Clear the latch so the refill trigger is re-evaluated at the new
        // position — a backward seek into cached audio must issue no work.
        isFilling = false
        // A seek is a fresh chance for any region that failed before.
        failedRanges.removeAll()
        supersedeInFlight()
        scheduleFillIfNeeded()
    }

    /// Called as the playhead advances, to top the window back up.
    func advance(to bookTime: Double) {
        playhead = bookTime
        scheduleFillIfNeeded()
    }

    func stop() {
        isRunning = false
        isFilling = false
        supersedeInFlight()
    }

    /// Backgrounding suspends work; foregrounding resumes it. Captions never
    /// request background execution time.
    func suspend() {
        isSuspended = true
        isFilling = false
        supersedeInFlight()
    }

    /// Cancel the current fill and bump the generation so its late completion
    /// is a no-op rather than clobbering whatever replaces it.
    private func supersedeInFlight() {
        generation += 1
        fillTask?.cancel()
        fillTask = nil
    }

    func resume() {
        isSuspended = false
        guard isRunning else { return }
        scheduleFillIfNeeded()
    }

    /// Test hook: wait for the in-flight fill chain to settle. Each non-superseded
    /// `runFill` either clears `fillTask` or replaces it with the next task before
    /// its value resolves, so looping until `fillTask == nil` drains the chain.
    func drainForTesting() async {
        while let task = fillTask {
            await task.value
        }
    }

    /// Hysteresis matters here. The *trigger* is the refill margin, but once
    /// triggered we fill all the way to `windowAhead`. Without the `isFilling`
    /// latch, every one-second playhead advance would issue a one-second
    /// request, and requests clipped at track boundaries would never chain.
    private func scheduleFillIfNeeded() {
        guard isRunning, !isSuspended, fillTask == nil else { return }

        let frontier = CaptionTimeline.coveredUntil(from: playhead, segments: segments)

        if !isFilling {
            guard frontier < playhead + refillMargin else { return }
            isFilling = true
        }

        guard frontier < playhead + windowAhead,
              let request = CaptionTimeline.nextRequest(playhead: playhead,
                                                        segments: segments,
                                                        tracks: tracks,
                                                        windowAhead: windowAhead),
              // Don't re-request a gap that already failed (range-keyed, so an
              // advancing playhead within the failed region stays suppressed).
              !failedRanges.contains(where: { $0.contains(request.bookOffset) })
        else {
            isFilling = false
            return
        }

        generation += 1
        let gen = generation
        fillTask = Task { [weak self] in
            await self?.runFill(request, generation: gen)
        }
    }

    private func runFill(_ request: TranscriptionRequest, generation gen: Int) async {
        var produced: [CaptionSegment] = []
        var failed = false

        if let fileURL = fileURLs[request.localFileId] {
            do {
                for try await segment in engine.transcribe(request: request, fileURL: fileURL) {
                    if Task.isCancelled { break }
                    produced.append(segment)
                }
            } catch {
                // A failed region is left uncovered rather than retried forever;
                // playback must never be disturbed by transcription trouble.
                logger.error("Caption transcription failed at \(request.bookOffset)s: \(error)")
                failed = true
            }
        } else {
            logger.error("Caption track file missing for id \(request.localFileId)")
            failed = true
        }

        // Superseded by a seek/stop/suspend (or a newer fill): discard silently,
        // and do NOT touch fillTask — it now belongs to the newer work.
        guard gen == generation else { return }
        fillTask = nil

        if failed {
            // Dam the failed range so it isn't retried until a seek; leave
            // isFilling clear so a later advance/seek can re-evaluate.
            failedRanges.append(request.bookOffset ..< (request.bookOffset + request.duration))
            isFilling = false
            return
        }

        if !produced.isEmpty {
            segments.append(contentsOf: produced)
            segments.sort { $0.start < $1.start }
            try? store.append(produced, locale: locale)
            onSegments(produced)
        }

        if isRunning { scheduleFillIfNeeded() }
    }
}
```

- [ ] **Step 6: Register both source files with the App target**

Follow **Procedure A** twice, with target `Audiobookshelf`:
- `Shared/util/captions/SegmentProducing.swift`
- `Shared/util/captions/CaptionScheduler.swift`

- [ ] **Step 7: Run the tests to verify they pass**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionSchedulerTests`.
Expected: `** TEST SUCCEEDED **`, 10 tests passing.

If `testRequestsChainAcrossATrackBoundary` sees only one request, the `isFilling` latch is being cleared too early — requests clipped at a track boundary must keep chaining until the frontier reaches `playhead + windowAhead`.

- [ ] **Step 8: Commit**

Use **Procedure B** (`commit-xcodeproj-changes` skill), including:

```
ios/App/Shared/util/captions/SegmentProducing.swift
ios/App/Shared/util/captions/CaptionScheduler.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionSchedulerTests.swift
ios/App/App.xcodeproj/project.pbxproj
```

Message: `feat(ios): sliding-window caption scheduler`

---

### Task 5: The iOS 26 speech transcription engine

**Files:**
- Create: `ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift`

**Interfaces:**
- Consumes: `SegmentProducing`, `TranscriptionRequest`, `CaptionSegment`, `CaptionWord`
- Produces: `@available(iOS 26.0, *) actor SpeechTranscriptionEngine: SegmentProducing`, plus `static func isAvailable(locale: Locale) async -> Bool` and `static func prepareModel(locale: Locale) async throws`

> **iOS 26 Speech API — reconciled against Apple's documentation (2026-07-22).** The signatures below were verified against `developer.apple.com/documentation/speech` (the doc-JSON declarations, which carry exact types). They are believed correct, but this plan still has not *compiled* against the iOS 26 SDK, so Step 1 remains a build-time confirmation gate. The one genuinely open detail is row 7 — how the `audioTimeRange` attribute is read off an `AttributedString` run — which Apple's rendered docs don't spell out; resolve it in Step 1.

Verified declarations (from Apple docs):

- `SpeechAnalyzer` is `final actor`. `init(modules:options:)`. Autonomous feed: `func start(inputSequence:)`. `func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule]) async -> AVAudioFormat?` — **static on `SpeechAnalyzer`**. Finish: `func finalizeAndFinishThroughEndOfInput() async throws` and `func finalizeAndFinish(through: CMTime) async throws`.
- `SpeechTranscriber` is `final class`. `convenience init(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with `Set<…>` option args, and `init(locale:preset:)`. `static var supportedLocales: [Locale] { get async }` and `static var installedLocales: [Locale] { get async }`. `var results: some Sendable & AsyncSequence<SpeechTranscriber.Result, any Error>`.
- `SpeechTranscriber.Result`: `var text: AttributedString`, `var range`, `var isFinal: Bool`, `var alternatives`, `resultsFinalizationTime`.
- `AssetInventory.assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest?`; `AssetInstallationRequest.downloadAndInstall()`. Allocation limits: `reserve(locale:)` / `release(reservedLocale:)`.
- `AnalyzerInput`: `init(buffer:)` and `init(buffer:bufferStartTime:)`.

- [ ] **Step 1: Confirm against the installed SDK and resolve the run-attribute accessor**

```bash
xcrun --sdk iphoneos --show-sdk-path
```

Open the Speech interface in Xcode (⇧⌘O → each of `SpeechAnalyzer`, `SpeechTranscriber`, `SpeechTranscriber.Result`, `AnalyzerInput`, `AssetInventory`). Confirm the declarations above compile as written. The **one** thing to actively discover — the rendered docs don't show it — is **row 7: how to read the per-run audio time range**. `Result.text` is an `AttributedString` produced with `attributeOptions: [.audioTimeRange]`. The accessor is one of:

- `run.audioTimeRange` (if the Speech attribute scope surfaces it as a dynamic member), or
- `run[AttributeScopes.SpeechAttributes.AudioTimeRangeAttribute.self]` / a similarly-named key, or
- iterate via `AttributedString.Runs` and read the attribute by its scope key.

Whichever the SDK exposes, it yields a `CMTimeRange` (or `CMTime` bounds). Wire it into `segment(from:)` in Step 2. If it turns out to be `CMTimeRange`, `.start.seconds` / `.end.seconds` are the field accesses used below.

Everything else in Step 2 already matches Apple's declarations; the only edit expected from this step is row 7.

- [ ] **Step 2: Write the engine**

Create `ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift`:

```swift
//
//  SpeechTranscriptionEngine.swift
//  Audiobookshelf
//
//  SegmentProducing backed by iOS 26's SpeechAnalyzer. This is the ONLY file
//  that touches the Speech framework's long-form API.
//
//  Reads one file region as a single continuous analysis rather than fixed
//  chunks: chunking would cut words at every seam, so seams exist only at real
//  track boundaries and seek points.
//

import Foundation
import AVFoundation
import Speech

@available(iOS 26.0, *)
actor SpeechTranscriptionEngine: SegmentProducing {

    enum EngineError: Error {
        case unsupportedLocale
        case unreadableAudio
    }

    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    static func isAvailable(locale: Locale) async -> Bool {
        // Verified: `supportedLocales` is `static var … [Locale] { get async }`.
        // Includes locales that are downloadable-but-not-yet-installed, which is
        // what we want — prepareModel() installs on demand. (`installedLocales`
        // exists too, for skipping the download prompt when already present.)
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Downloads the on-device language model if it isn't installed yet.
    /// Requires network on first use for a given language.
    static func prepareModel(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    nonisolated func transcribe(request: TranscriptionRequest, fileURL: URL) -> AsyncThrowingStream<CaptionSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request: request, fileURL: fileURL, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(request: TranscriptionRequest,
                     fileURL: URL,
                     continuation: AsyncThrowingStream<CaptionSegment, Error>.Continuation) async throws {

        // Finalized results only — we run ahead of the playhead, so provisional
        // guesses would only cause visible rewriting for no benefit.
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Verified: bestAvailableAudioFormat is static on SpeechAnalyzer (NOT
        // on SpeechTranscriber) and returns AVAudioFormat?.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.unreadableAudio
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Consume results CONCURRENTLY with feeding + finalizing. `transcriber.results`
        // does not complete until the analyzer is finalized, and finalization is issued
        // below AFTER the input is finished — so draining `results` inline before that
        // call would DEADLOCK. Mirror Apple's WWDC pattern: spin the results consumer up
        // first, feed, finish input, then finalize (which ends the results sequence and
        // lets this child task return). Finalize ordering is confirmed on device in Task 9.
        //
        // Finalized results only: filter on isFinal so provisional guesses (we didn't
        // request volatile reporting) never reach the UI.
        let resultsTask = Task { () throws in
            for try await result in transcriber.results {
                if Task.isCancelled { break }
                guard result.isFinal else { continue }
                if let segment = Self.segment(from: result, bookOffset: request.bookOffset) {
                    continuation.yield(segment)
                }
            }
        }

        // `resultsTask` is unstructured, so it does not inherit this (outer stream) task's
        // cancellation. Bridge it explicitly — the role the old feeder cancel played.
        try await withTaskCancellationHandler {
            // Verified: `start(inputSequence:)` returns promptly once autonomous background
            // analysis begins (async throws -> Void), distinct from `analyzeSequence` which
            // returns CMTime? only after consuming the whole sequence — so feeding AFTER
            // this call is correct.
            do {
                try await analyzer.start(inputSequence: inputStream)
                try await self.feed(fileURL: fileURL,
                                    request: request,
                                    analyzerFormat: analyzerFormat,
                                    into: inputContinuation)
            } catch {
                inputContinuation.finish()
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            inputContinuation.finish()
            // Verified: SpeechAnalyzer.finalizeAndFinishThroughEndOfInput() async throws.
            // Finalizing completes `transcriber.results`, which ends `resultsTask`.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultsTask.value
        } onCancel: {
            inputContinuation.finish()
            resultsTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Decode `request.duration` seconds starting at `request.offsetInTrack`,
    /// converting every buffer into the analyzer's exact format before feeding.
    ///
    /// Offset math, and why it's robust: we build a FRESH analyzer per request and
    /// feed it starting at `offsetInTrack`, and `AVAudioPCMBuffer`s carry no
    /// timestamps. So the analyzer counts time from zero at the first fed frame,
    /// making `.audioTimeRange` values relative to the START of this request's
    /// audio. Book time is therefore `request.bookOffset + reportedTime` — see
    /// `segment(from:bookOffset:)`. Because the sequence starts at zero we do NOT
    /// set `AnalyzerInput.bufferStartTime`. **Task 9 must confirm this assumption
    /// on device** — if the analyzer instead reports asset-timeline times, the
    /// shift becomes `track.startOffset + reportedTime` and this is the one line
    /// to change.
    private func feed(fileURL: URL,
                      request: TranscriptionRequest,
                      analyzerFormat: AVAudioFormat,
                      into continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {

        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EngineError.unreadableAudio
        }

        // AVAssetReader rather than AVAudioFile: AVAudioFile is unreliable on .m4b.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: request.offsetInTrack, preferredTimescale: 600),
            duration: CMTime(seconds: request.duration, preferredTimescale: 600)
        )

        // Read as canonical deinterleaved float32 mono. This is the reader's
        // OUTPUT format; AVAudioConverter then bridges it to whatever the
        // analyzer wants (sample rate, interleaving, bit depth may all differ).
        let readerSampleRate = analyzerFormat.sampleRate
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: readerSampleRate,
            AVNumberOfChannelsKey: 1
        ]
        guard let readerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: readerSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw EngineError.unreadableAudio
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw EngineError.unreadableAudio }

        // Converter is identity when readerFormat == analyzerFormat; correct
        // otherwise. Never memcpy across mismatched layouts.
        let formatsDiffer = readerFormat != analyzerFormat
        let converter = AVAudioConverter(from: readerFormat, to: analyzerFormat)
        // If a converter is REQUIRED but couldn't be created, fail loudly rather
        // than silently feeding wrong-format audio into the analyzer.
        if formatsDiffer, converter == nil { throw EngineError.unreadableAudio }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { break }
            guard let readerBuffer = Self.pcmBuffer(from: sampleBuffer, format: readerFormat) else { continue }

            let outBuffer: AVAudioPCMBuffer
            if formatsDiffer, let converter {
                guard let converted = Self.convert(readerBuffer, using: converter, to: analyzerFormat) else { continue }
                outBuffer = converted
            } else {
                outBuffer = readerBuffer
            }
            // Row 8: fresh sequence from zero ⇒ no bufferStartTime.
            continuation.yield(AnalyzerInput(buffer: outBuffer))
        }

        if reader.status == .failed { throw reader.error ?? EngineError.unreadableAudio }
        reader.cancelReading()
    }

    /// Copy a decoded CMSampleBuffer into an AVAudioPCMBuffer of `format` using
    /// the audio buffer list — safe across channel/layout, unlike a raw memcpy.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    /// Run `input` through `converter` into a buffer of `outFormat`.
    private static func convert(_ input: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let statusValue = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, statusValue != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Convert one recognizer result into a book-time segment.
    /// `.audioTimeRange` gives request-relative times; `bookOffset` shifts them
    /// (see the offset-math note on `feed`).
    private static func segment(from result: SpeechTranscriber.Result, bookOffset: Double) -> CaptionSegment? {
        let attributed = result.text
        let plain = String(attributed.characters)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var words: [CaptionWord] = []
        for run in attributed.runs {
            // ⚠️ ROW 7 — the single accessor to confirm in Step 1. `Result.text`
            // was produced with `attributeOptions: [.audioTimeRange]`, so each run
            // carries a CMTimeRange. If `run.audioTimeRange` doesn't resolve, read
            // it via the Speech AttributeScope key (see Step 1) — same CMTimeRange.
            guard let range = run.audioTimeRange else { continue }
            let text = String(attributed[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            words.append(CaptionWord(
                start: bookOffset + range.start.seconds,
                end: bookOffset + range.end.seconds,
                text: text
            ))
        }

        guard let first = words.first, let last = words.last else { return nil }
        return CaptionSegment(start: first.start, end: last.end, text: plain, words: words)
    }
}
```

- [ ] **Step 3: Register the source file with the App target**

Follow **Procedure A** with `Shared/util/captions/SpeechTranscriptionEngine.swift` and target `Audiobookshelf`.

- [ ] **Step 4: Build to verify it compiles**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild build -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If symbol errors appear, return to Step 1 and correct the signatures against the SDK — do not guess repeatedly.

- [ ] **Step 5: Add the fixture integration test**

Record roughly 20 seconds of clear spoken English (any voice memo exported to `.m4a` works) and save it as `ios/App/AudiobookshelfUnitTests/Fixtures/speech-sample.m4a`. Register it with the `AudiobookshelfUnitTests` target as a **bundle resource** (Xcode: select the file → Target Membership → check `AudiobookshelfUnitTests`; it must appear under Build Phases → Copy Bundle Resources, not Compile Sources).

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/SpeechTranscriptionEngineTests.swift`:

```swift
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
        try XCTSkipUnless(await SpeechTranscriptionEngine.isAvailable(locale: Locale(identifier: "en-US")),
                          "en-US speech model unavailable on this machine")
    }

    func testProducesTimedSegmentsShiftedIntoBookTime() async throws {
        let locale = Locale(identifier: "en-US")
        try XCTSkipUnless(await SpeechTranscriptionEngine.isAvailable(locale: locale),
                          "en-US speech model unavailable on this machine")
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
```

Register the test file via **Procedure A** with target `AudiobookshelfUnitTests`.

- [ ] **Step 6: Run the full test suite**

```bash
xcodebuild test -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AudiobookshelfUnitTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. The two engine tests may report as *skipped* if the simulator has no en-US speech model installed — that is an acceptable result here, because Task 9 verifies the engine on hardware. Skipped is acceptable; **failed is not**.

- [ ] **Step 7: Commit**

Use **Procedure B** (`commit-xcodeproj-changes` skill), including:

```
ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/SpeechTranscriptionEngineTests.swift
ios/App/AudiobookshelfUnitTests/Fixtures/speech-sample.m4a
ios/App/App.xcodeproj/project.pbxproj
```

Message: `feat(ios): SpeechAnalyzer-backed transcription engine`

---

### Task 6: The `AbsTranscriber` Capacitor plugin

**Files:**
- Create: `ios/App/App/plugins/AbsTranscriber.swift`
- Create: `plugins/capacitor/AbsTranscriber.js`
- Modify: `plugins/capacitor/index.js`
- Modify: `ios/App/App/Info.plist`

**Interfaces:**
- Consumes: `CaptionScheduler`, `CaptionStore`, `SpeechTranscriptionEngine`, `CaptionTrack`, `CaptionSegment`
- Produces, on the JS side:
  - `AbsTranscriber.isSupported() -> { supported: boolean, reason: string }` where `reason` is one of `'ok' | 'os' | 'permission' | 'locale' | 'model'`
  - `AbsTranscriber.enable({ libraryItemId: string, currentTime: number })`
  - `AbsTranscriber.updateTime({ currentTime: number })` — called on every player time report. A jump larger than 5s is treated as a seek; anything smaller advances the window.
  - `AbsTranscriber.disable()`
  - Event `onCaptionSegments` → `{ segments: [{ start, end, text, words: [{ start, end, text }] }] }`
  - Event `onCaptionStatus` → `{ status: 'preparing' | 'downloading-model' | 'ready' | 'error', message?: string }`

The plugin also owns background suspension: it observes `UIApplication.didEnterBackgroundNotification` and `willEnterForegroundNotification` and forwards them to `CaptionScheduler.suspend()` / `.resume()`.

- [ ] **Step 1: Add the Info.plist usage description**

Add to `ios/App/App/Info.plist`, inside the top-level `<dict>`:

```xml
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Audiobookshelf uses on-device speech recognition to show captions while you listen. Your audio never leaves your device.</string>
```

- [ ] **Step 2: Write the plugin**

Create `ios/App/App/plugins/AbsTranscriber.swift`:

```swift
//
//  AbsTranscriber.swift
//  App
//
//  Capacitor surface for read-while-listening captions. This is the ONLY file
//  permitted to contain an iOS 26 availability check — everything below it is
//  version-agnostic.
//

import Foundation
import UIKit
import Capacitor
import Speech
import RealmSwift

@objc(AbsTranscriber)
public class AbsTranscriber: CAPPlugin, CAPBridgedPlugin {
    public var identifier = "AbsTranscriberPlugin"
    public var jsName = "AbsTranscriber"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateTime", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disable", returnType: CAPPluginReturnPromise)
    ]

    private var scheduler: CaptionScheduler?
    private var lastReportedTime: Double = 0

    // MARK: - Background handling

    override public func load() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        Task { await self.scheduler?.suspend() }
    }

    @objc private func appWillEnterForeground() {
        Task { await self.scheduler?.resume() }
    }

    // MARK: - Capability

    @objc func isSupported(_ call: CAPPluginCall) {
        guard #available(iOS 26.0, *) else {
            call.resolve(["supported": false, "reason": "os"])
            return
        }
        Task {
            let status = SFSpeechRecognizer.authorizationStatus()
            guard status == .authorized || status == .notDetermined else {
                call.resolve(["supported": false, "reason": "permission"])
                return
            }
            let available = await SpeechTranscriptionEngine.isAvailable(locale: Locale.current)
            call.resolve(["supported": available, "reason": available ? "ok" : "locale"])
        }
    }

    // MARK: - Lifecycle

    @objc func enable(_ call: CAPPluginCall) {
        guard #available(iOS 26.0, *) else {
            call.reject("Captions require iOS 26 or later")
            return
        }
        guard let libraryItemId = call.getString("libraryItemId") else {
            call.reject("libraryItemId is required")
            return
        }
        let currentTime = call.getDouble("currentTime") ?? 0
        lastReportedTime = currentTime

        Task {
            do {
                try await self.requestAuthorization()
            } catch {
                self.notifyStatus("error", "Speech recognition permission was denied")
                call.reject("Speech recognition permission was denied")
                return
            }

            self.notifyStatus("downloading-model", nil)
            do {
                try await SpeechTranscriptionEngine.prepareModel(locale: Locale.current)
            } catch {
                self.notifyStatus("error", "Could not download language support")
                call.reject("Could not download language support")
                return
            }

            guard let context = self.buildContext(libraryItemId: libraryItemId) else {
                self.notifyStatus("error", "This book is not downloaded")
                call.reject("This book is not downloaded")
                return
            }

            self.notifyStatus("preparing", nil)

            let engine = SpeechTranscriptionEngine(locale: Locale.current)
            let scheduler = CaptionScheduler(
                tracks: context.tracks,
                fileURLs: context.fileURLs,
                store: CaptionStore(directory: context.directory),
                engine: engine,
                locale: Locale.current.identifier(.bcp47),
                onSegments: { [weak self] segments in
                    self?.notifySegments(segments)
                }
            )
            self.scheduler = scheduler
            await scheduler.start(at: currentTime)
            self.notifyStatus("ready", nil)
            call.resolve()
        }
    }

    /// Called on every player time report. Small deltas keep the window topped
    /// up as playback progresses; a large jump is a seek and discards in-flight
    /// work for the region the listener just left.
    @objc func updateTime(_ call: CAPPluginCall) {
        let currentTime = call.getDouble("currentTime") ?? 0
        let isSeek = abs(currentTime - lastReportedTime) > 5
        lastReportedTime = currentTime

        Task {
            if isSeek {
                await self.scheduler?.seek(to: currentTime)
            } else {
                await self.scheduler?.advance(to: currentTime)
            }
            call.resolve()
        }
    }

    @objc func disable(_ call: CAPPluginCall) {
        Task {
            await self.scheduler?.stop()
            self.scheduler = nil
            call.resolve()
        }
    }

    // MARK: - Helpers

    private struct Context {
        let tracks: [CaptionTrack]
        let fileURLs: [String: URL]
        let directory: URL
    }

    /// Flatten the Realm item into the value types the scheduler understands.
    private func buildContext(libraryItemId: String) -> Context? {
        guard let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: libraryItemId)
                ?? Database.shared.getLocalLibraryItem(localLibraryItemId: libraryItemId),
              item.isBook,
              let media = item.media,
              let directory = item.contentDirectory
        else { return nil }

        var tracks: [CaptionTrack] = []
        var fileURLs: [String: URL] = [:]

        for (offset, track) in media.tracks.enumerated() {
            guard let localFileId = track.localFileId,
                  let localFile = item.localFiles.first(where: { $0.id == localFileId })
            else { continue }
            // AudioTrack.index and serverIndex are both Int? in the Realm model;
            // fall back to enumeration order so CaptionTrack.index is always set.
            let index = track.index ?? track.serverIndex ?? offset
            tracks.append(CaptionTrack(index: index,
                                       startOffset: track.startOffset ?? 0,
                                       duration: track.duration,
                                       localFileId: localFileId))
            fileURLs[localFileId] = localFile.contentPath
        }

        guard !tracks.isEmpty else { return nil }
        return Context(tracks: tracks, fileURLs: fileURLs, directory: directory)
    }

    private func requestAuthorization() async throws {
        struct Denied: Error {}
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Denied() }
    }

    private func notifySegments(_ segments: [CaptionSegment]) {
        let payload = segments.map { segment -> [String: Any] in
            [
                "start": segment.start,
                "end": segment.end,
                "text": segment.text,
                "words": segment.words.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
            ]
        }
        notifyListeners("onCaptionSegments", data: ["segments": payload])
    }

    private func notifyStatus(_ status: String, _ message: String?) {
        var data: [String: Any] = ["status": status]
        if let message { data["message"] = message }
        notifyListeners("onCaptionStatus", data: data)
    }
}
```

**Verify before building:** the two `Database.shared` lookup method names above must match the real API in `ios/App/Shared/util/Database.swift`. Run `grep -n "func getLocalLibraryItem" ios/App/Shared/util/Database.swift` and correct the calls to the actual signatures.

- [ ] **Step 3: Write the JS wrapper**

Create `plugins/capacitor/AbsTranscriber.js`:

```js
import { registerPlugin, WebPlugin } from '@capacitor/core'

class AbsTranscriberWeb extends WebPlugin {
  constructor() {
    super()
  }

  async isSupported() {
    return { supported: false, reason: 'os' }
  }

  async enable() {}
  async updateTime() {}
  async disable() {}
}

const AbsTranscriber = registerPlugin('AbsTranscriber', {
  web: () => new AbsTranscriberWeb()
})

export { AbsTranscriber }
```

- [ ] **Step 4: Export it from the plugin index**

Modify `plugins/capacitor/index.js`:

```js
import Vue from 'vue'
import { AbsAudioPlayer } from './AbsAudioPlayer'
import { AbsDownloader } from './AbsDownloader'
import { AbsFileSystem } from './AbsFileSystem'
import { AbsDatabase } from './AbsDatabase'
import { AbsLogger } from './AbsLogger'
import { AbsTranscriber } from './AbsTranscriber'
import { Capacitor } from '@capacitor/core'

Vue.prototype.$platform = Capacitor.getPlatform()

export { AbsAudioPlayer, AbsDownloader, AbsFileSystem, AbsLogger, AbsDatabase, AbsTranscriber }
```

- [ ] **Step 5: Register the plugin source with the App target**

Follow **Procedure A** with `App/plugins/AbsTranscriber.swift` and target `Audiobookshelf`.

- [ ] **Step 5b: Register the plugin instance with the Capacitor bridge**

This app does NOT auto-discover Capacitor plugins — it registers each explicitly in `ios/App/App/MyViewController.swift`'s `capacitorDidLoad()`, alongside the other `Abs*` plugins. Without this the plugin links but is unreachable from JS (`AbsTranscriber` calls silently no-op). Add, matching the sibling registrations:

```swift
        bridge?.registerPluginInstance(AbsTranscriber())
```

- [ ] **Step 6: Build to verify it compiles**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild build -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

Use **Procedure B** (`commit-xcodeproj-changes` skill), including:

```
ios/App/App/plugins/AbsTranscriber.swift
ios/App/App/Info.plist
plugins/capacitor/AbsTranscriber.js
plugins/capacitor/index.js
ios/App/App.xcodeproj/project.pbxproj
```

Message: `feat(ios): AbsTranscriber capacitor plugin for captions`

---

### Task 7: The interpolating caption clock

**Files:**
- Create: `utils/captionClock.js`

**Interfaces:**
- Consumes: nothing
- Produces: `createAnchor({ bookTime, rate, isPlaying, now })`, `estimateBookTime(anchor, now)`, `findActiveWord(segments, bookTime)`, `pruneSegments(segments, bookTime, radius)`

There is no JavaScript test infrastructure in this repo and adding one is out of scope. These functions are pure and dependency-free specifically so they can be reasoned about directly and tested the moment such infrastructure exists.

- [ ] **Step 1: Write the module**

Create `utils/captionClock.js`:

```js
/**
 * Pure caption timing math.
 *
 * The native player only reports currentTime once per second, which is far too
 * coarse for word-level highlighting. Rather than polling native harder, we treat
 * each report as an ANCHOR and interpolate locally against wall-clock time,
 * re-anchoring on every report. Drift is therefore bounded by the poll interval.
 *
 * No Vue, no Capacitor, no side effects.
 */

/**
 * @param {{ bookTime: number, rate: number, isPlaying: boolean, now: number }} params
 *   `now` is a performance.now() reading, in milliseconds.
 */
export function createAnchor({ bookTime, rate, isPlaying, now }) {
  return {
    bookTime: Number(bookTime) || 0,
    rate: Number(rate) > 0 ? Number(rate) : 1,
    isPlaying: !!isPlaying,
    wallClock: Number(now) || 0
  }
}

/** Estimated book time at `now`. A paused anchor never advances. */
export function estimateBookTime(anchor, now) {
  if (!anchor) return 0
  if (!anchor.isPlaying) return anchor.bookTime
  const elapsedSeconds = (now - anchor.wallClock) / 1000
  return anchor.bookTime + elapsedSeconds * anchor.rate
}

/**
 * Binary-search `segments` (sorted by start) for the word covering `bookTime`.
 * Returns `{ segmentIndex, wordIndex }`, or null when nothing covers it.
 */
export function findActiveWord(segments, bookTime) {
  if (!segments || !segments.length) return null

  let lo = 0
  let hi = segments.length - 1
  let found = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    const segment = segments[mid]
    if (bookTime < segment.start) {
      hi = mid - 1
    } else if (bookTime > segment.end) {
      lo = mid + 1
    } else {
      found = mid
      break
    }
  }
  if (found === -1) return null

  const words = segments[found].words || []
  for (let i = 0; i < words.length; i++) {
    if (bookTime >= words[i].start && bookTime <= words[i].end) {
      return { segmentIndex: found, wordIndex: i }
    }
  }
  // Inside the segment but in a gap between words — hold the previous word.
  let previous = -1
  for (let i = 0; i < words.length; i++) {
    if (words[i].start <= bookTime) previous = i
  }
  return previous === -1 ? { segmentIndex: found, wordIndex: 0 } : { segmentIndex: found, wordIndex: previous }
}

/**
 * Drop segments further than `radius` seconds from `bookTime`, so a long
 * session cannot accumulate a whole book's text in the WebView.
 */
export function pruneSegments(segments, bookTime, radius) {
  if (!segments) return []
  return segments.filter((s) => s.end >= bookTime - radius && s.start <= bookTime + radius)
}

/** Merge new segments into a sorted list, replacing any with the same start. */
export function mergeSegments(existing, incoming) {
  const byStart = new Map()
  for (const segment of existing || []) byStart.set(Math.round(segment.start * 1000), segment)
  for (const segment of incoming || []) byStart.set(Math.round(segment.start * 1000), segment)
  return Array.from(byStart.values()).sort((a, b) => a.start - b.start)
}
```

- [ ] **Step 2: Verify the module parses**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
node --input-type=module -e "
import { createAnchor, estimateBookTime, findActiveWord, mergeSegments, pruneSegments } from './utils/captionClock.js'
const a = createAnchor({ bookTime: 100, rate: 2, isPlaying: true, now: 1000 })
console.assert(estimateBookTime(a, 2000) === 102, 'rate-scaled interpolation')
const paused = createAnchor({ bookTime: 50, rate: 1, isPlaying: false, now: 0 })
console.assert(estimateBookTime(paused, 99999) === 50, 'paused anchor holds')
const segs = [{ start: 0, end: 2, words: [{ start: 0, end: 1, text: 'a' }, { start: 1, end: 2, text: 'b' }] }]
console.assert(JSON.stringify(findActiveWord(segs, 1.5)) === '{\"segmentIndex\":0,\"wordIndex\":1}', 'word lookup')
console.assert(findActiveWord(segs, 99) === null, 'no coverage returns null')
console.assert(mergeSegments(segs, segs).length === 1, 'merge dedupes')
console.assert(pruneSegments(segs, 1000, 10).length === 0, 'prune drops distant')
console.log('captionClock OK')
"
```

Expected output: `captionClock OK` with no assertion failures.

- [ ] **Step 3: Commit**

```bash
git add utils/captionClock.js
git commit -m "feat: pure caption clock and segment lookup helpers"
```

---

### Task 8: Caption panel and player integration

**Files:**
- Create: `components/player/CaptionPanel.vue`
- Modify: `components/app/AudioPlayer.vue` (cover block at lines 33-41, plus script)

**Interfaces:**
- Consumes: `AbsTranscriber` from Task 6, `utils/captionClock.js` from Task 7
- Produces: a `<player-caption-panel>` component taking props `currentTime` (Number, book seconds), `isPlaying` (Boolean), `playbackRate` (Number), `libraryItemId` (String), `width` (Number)

- [ ] **Step 1: Write the caption panel**

Create `components/player/CaptionPanel.vue`:

```vue
<template>
  <div class="caption-panel w-full h-full flex items-center justify-center px-4" :style="{ width: width + 'px' }">
    <p v-if="status === 'error'" class="text-center text-fg text-opacity-75 text-sm">{{ statusMessage }}</p>
    <p v-else-if="status === 'downloading-model'" class="text-center text-fg text-opacity-75 text-sm">{{ $strings.MessageDownloadingLanguageSupport }}</p>
    <p v-else-if="!visibleWords.length" class="text-center text-fg text-opacity-50 text-sm">{{ $strings.MessagePreparingCaptions }}</p>
    <p v-else class="caption-text text-center text-fg leading-relaxed">
      <span v-for="(word, index) in visibleWords" :key="index" :class="word.isActive ? 'text-fg font-semibold' : 'text-fg text-opacity-60'">{{ word.text }}</span>
    </p>
  </div>
</template>

<script>
import { AbsTranscriber } from '@/plugins/capacitor'
import { createAnchor, estimateBookTime, findActiveWord, mergeSegments, pruneSegments } from '@/utils/captionClock'

export default {
  props: {
    currentTime: { type: Number, default: 0 },
    isPlaying: { type: Boolean, default: false },
    playbackRate: { type: Number, default: 1 },
    libraryItemId: { type: String, default: null },
    width: { type: Number, default: 300 }
  },
  data() {
    return {
      segments: [],
      anchor: null,
      estimatedTime: 0,
      status: 'preparing',
      statusMessage: '',
      rafHandle: null
    }
  },
  computed: {
    // Show the active segment's words, so the reader gets a sentence of context.
    visibleWords() {
      const active = findActiveWord(this.segments, this.estimatedTime)
      if (!active) return []
      const segment = this.segments[active.segmentIndex]
      return (segment.words || []).map((word, index) => ({
        text: index === 0 ? word.text : ' ' + word.text,
        isActive: index === active.wordIndex
      }))
    }
  },
  watch: {
    // Every native time report re-anchors the clock (bounding drift) and tells
    // the scheduler where we are, so the window keeps topping up as we listen.
    currentTime() {
      this.reanchor()
      AbsTranscriber.updateTime({ currentTime: this.currentTime })
    },
    isPlaying() {
      this.reanchor()
    },
    playbackRate() {
      this.reanchor()
    }
  },
  methods: {
    reanchor() {
      this.anchor = createAnchor({
        bookTime: this.currentTime,
        rate: this.playbackRate,
        isPlaying: this.isPlaying,
        now: performance.now()
      })
    },
    tick() {
      this.estimatedTime = estimateBookTime(this.anchor, performance.now())
      this.rafHandle = requestAnimationFrame(this.tick)
    },
    onCaptionSegments(data) {
      const merged = mergeSegments(this.segments, data.segments || [])
      this.segments = pruneSegments(merged, this.estimatedTime, 1800)
    },
    onCaptionStatus(data) {
      this.status = data.status
      this.statusMessage = data.message || ''
    }
  },
  async mounted() {
    this.reanchor()
    this.tick()

    this.captionSegmentsListener = await AbsTranscriber.addListener('onCaptionSegments', this.onCaptionSegments)
    this.captionStatusListener = await AbsTranscriber.addListener('onCaptionStatus', this.onCaptionStatus)

    try {
      await AbsTranscriber.enable({ libraryItemId: this.libraryItemId, currentTime: this.currentTime })
    } catch (error) {
      this.status = 'error'
      this.statusMessage = error.message || 'Captions unavailable'
    }
  },
  beforeDestroy() {
    if (this.rafHandle) cancelAnimationFrame(this.rafHandle)
    this.captionSegmentsListener?.remove()
    this.captionStatusListener?.remove()
    AbsTranscriber.disable()
  }
}
</script>

<style scoped>
.caption-text {
  font-size: 1.05rem;
  max-height: 100%;
  overflow: hidden;
}
</style>
```

- [ ] **Step 2: Add the strings used above**

Add to `strings/en-us.json`, keeping the file's alphabetical ordering:

```json
  "MessageDownloadingLanguageSupport": "Downloading language support…",
  "MessagePreparingCaptions": "Preparing captions…",
  "MessageCaptionsAccuracyNotice": "Captions are generated on your device from the audio. Names and unusual words may be transcribed incorrectly.",
  "MessageCaptionsRequireDownload": "Download this book to read along with captions.",
  "LabelCaptions": "Captions",
```

`MessageCaptionsAccuracyNotice` is shown once, the first time captions are enabled, so the accuracy limitation is disclosed rather than discovered. Step 5 wires it up.

Verify the file still parses:

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
node -e "JSON.parse(require('fs').readFileSync('strings/en-us.json','utf8')); console.log('strings OK')"
```

Expected: `strings OK`.

- [ ] **Step 3: Swap the cover block in the player**

In `components/app/AudioPlayer.vue`, the cover block is the `cover-wrapper` div (currently lines 33-41). Confirm its exact bounds first — `grep -n 'cover-wrapper' components/app/AudioPlayer.vue` — then replace that whole div with:

```html
    <div class="cover-wrapper absolute z-30 pointer-events-auto" @click="clickContainer">
      <div class="w-full h-full flex justify-center">
        <player-caption-panel v-if="showCaptions" :current-time="currentTime" :is-playing="isPlaying" :playback-rate="currentPlaybackRate" :library-item-id="captionLibraryItemId" :width="bookCoverWidth" />
        <covers-book-cover v-else-if="coverUrl" ref="cover" :download-cover="coverUrl" :width="bookCoverWidth" :book-cover-aspect-ratio="bookCoverAspectRatio" raw @imageLoaded="coverImageLoaded" />
      </div>

      <div v-if="syncStatus === $constants.SyncStatus.FAILED" class="absolute top-0 left-0 w-full h-full flex items-center justify-center z-30" @click.stop="showSyncsFailedDialog">
        <span class="material-symbols text-error text-3xl">error</span>
      </div>
    </div>
```

- [ ] **Step 4: Add the CC toggle button**

The fullscreen header controls are absolute-positioned siblings inside the `v-if="showFullscreen"` background div (the one opening at line 3). The existing right-side icons sit at `right-4` (more_vert) and `right-16` (cast, `v-show="showCastBtn"`). Place the CC button clear of both — at `right-28` — as a new sibling among those icon divs (immediately after the `more_vert` div):

```html
      <div v-if="captionsButtonVisible" class="top-6 right-28 absolute cursor-pointer" @click="toggleCaptions">
        <span class="material-symbols text-3xl"
              :class="[!captionsEnabled ? 'text-fg text-opacity-30' : showCaptions ? 'text-fg' : 'text-fg text-opacity-60', { 'text-black text-opacity-75': coverBgIsLight && theme !== 'black' }]">closed_caption</span>
      </div>
```

The button is **visible** whenever the platform supports captions and a book is loaded, but rendered **dimmed/disabled** for a streaming book; `toggleCaptions` shows the "requires download" toast in that state (per the spec's "Book not downloaded" row). When `showCastBtn` is false the cast slot at `right-16` is empty, leaving a gap — acceptable, since the CC button keeps a fixed position rather than reflowing.

- [ ] **Step 5: Wire up the script**

In `components/app/AudioPlayer.vue`, add to the `import` block:

```js
import { AbsTranscriber } from '@/plugins/capacitor'
```

Add to `data()`:

```js
      showCaptions: false,
      // iOS 26 present. Constant for the life of the app, so it's checked once.
      captionsPlatformSupported: false,
```

Split the two gates deliberately. **Platform support (iOS 26) is constant** and is checked a single time at mount. **Book-downloaded state is reactive** off `playbackSession`, so it re-evaluates on every book without any watcher. This is what avoids the mount-timing bug: `checkCaptionsPlatformSupported()` never reads `isLocalPlayMethod`, so it doesn't matter that `playbackSession` is still null at mount.

Add to `methods`:

```js
    toggleCaptions() {
      // Per spec, the button is visible but disabled for a streaming (not
      // downloaded) book — explain rather than silently do nothing.
      if (!this.captionsEnabled) {
        this.$toast.info(this.$strings.MessageCaptionsRequireDownload)
        return
      }
      this.showCaptions = !this.showCaptions
      // Disclose the ASR accuracy limitation once, on first enable, rather than
      // letting the user discover it via a mangled character name.
      if (this.showCaptions && !localStorage.getItem('captionsAccuracyNoticeShown')) {
        localStorage.setItem('captionsAccuracyNoticeShown', '1')
        this.$toast.info(this.$strings.MessageCaptionsAccuracyNotice, { timeout: 8000 })
      }
    },
    async checkCaptionsPlatformSupported() {
      if (this.$platform !== 'ios') {
        this.captionsPlatformSupported = false
        return
      }
      try {
        // reason === 'os' means iOS < 26 — the only case that hides the button.
        // 'permission' and 'locale' still show the button; the panel explains them.
        const result = await AbsTranscriber.isSupported()
        this.captionsPlatformSupported = result.reason !== 'os'
      } catch (error) {
        this.captionsPlatformSupported = false
      }
    },
```

Add computed properties:

```js
    // Visible whenever the platform supports captions and a book is loaded.
    captionsButtonVisible() {
      return this.captionsPlatformSupported && !!this.playbackSession
    },
    // Enabled only for a downloaded (local) book.
    captionsEnabled() {
      return this.isLocalPlayMethod
    },
    // Captions run against the downloaded item. localLibraryItem.id is the
    // "local_…" id the native plugin resolves via getLocalLibraryItem.
    captionLibraryItemId() {
      return this.localLibraryItem?.id || this.playbackSession?.libraryItemId || null
    },
```

Add a `watch` so captions never leak across books:

```js
    playbackSession(newSession, oldSession) {
      if (newSession?.libraryItemId !== oldSession?.libraryItemId) {
        this.showCaptions = false
      }
    },
```

Call `this.checkCaptionsPlatformSupported()` at the end of the existing `mounted()` hook.

**Verify these names before running** — confirm the real symbols this uses all exist in the component (they were verified against the current file, but re-check):

```bash
grep -n "isLocalPlayMethod\|localLibraryItem\b\|playbackSession\b\|currentPlaybackRate\|onPlaybackSession" components/app/AudioPlayer.vue | head
```

`playbackSession` is a component `data` field (not a store getter); `localLibraryItem` and `isLocalPlayMethod` are existing computeds; `currentPlaybackRate` is existing `data`. Do **not** reference `$store.state.playerLibraryItemId` — it does not exist.

- [ ] **Step 6: Build the web layer and sync**

**Use `nuxt generate`, NOT `nuxt build`.** Capacitor's `webDir` is `dist/`, which is produced ONLY by `nuxt generate` (static export). `npm run build` = `nuxt build` produces `.nuxt/` (SSR) and does NOT refresh `dist/`, so `cap sync` would copy a STALE `dist/` and the caption code would never reach the device. The repo's `npm run sync` does the right thing:

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
npm run generate && npx cap sync ios 2>&1 | tail -20
# (equivalently: npm run sync)
```

Expected: generate completes, `cap sync` reports success.

**Verify the caption code actually landed in the deployed bundle** (a compile-only check is NOT sufficient — it won't catch a stale `dist/`):

```bash
grep -rl "captionsPlatformSupported\|AbsTranscriber" ios/App/App/public/ | head
```

Expected: at least one `ios/App/App/public/_nuxt/*.js` match. If empty, the sync copied stale assets — re-run `npm run generate` first.

- [ ] **Step 7: Commit**

```bash
git add components/player/CaptionPanel.vue components/app/AudioPlayer.vue strings/en-us.json
git commit -m "feat: caption panel and player CC toggle"
```

---

### Task 9: Device verification pass

**Files:** none — this task changes no code unless it finds a defect.

Simulator speech-model availability is unreliable, so correctness is established on hardware. Every check below must be performed on a physical iOS 26 device with a fully downloaded audiobook.

- [ ] **Step 1: Install on a device**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build 2>&1 | tail -20
```

Then run from Xcode on the connected device.

- [ ] **Step 2: Verify the capability gate**

Confirm the CC button is **hidden** while playing a book that is streaming (not downloaded), and **visible** for a downloaded book. Record both results.

- [ ] **Step 3: Verify first-run permission and model download**

Tap CC for the first time. Expected: the system speech-recognition permission prompt appears with the Info.plist copy, then a "Downloading language support…" state, then captions.

Deny permission on a second device or after resetting privacy (Settings → General → Transfer or Reset → Reset Location & Privacy) and confirm the panel shows the error state rather than hanging on "Preparing captions…".

- [ ] **Step 4: Verify sync at 1x and 2x, and the offset-math assumption**

Play at 1x for two minutes. The highlighted word should track the narrated word without visible drift. Repeat at 2x. Record any drift you observe and where it appears.

**Critical:** start playback at a position **deep in the book** (e.g. an hour in, well into a later track) with no cached captions there, enable captions, and confirm the words align with *that* audio — not audio from the start of the file or book. A constant offset (captions consistently N seconds early/late, or showing text from 0:00) means the `feed` offset-math assumption is wrong: the analyzer is reporting asset-timeline times, not request-relative times. If so, change the shift in `segment(from:bookOffset:)` per the note on `feed` (use `track.startOffset + reportedTime`) and re-verify. This is the single most likely place for the engine to be subtly wrong.

- [ ] **Step 5: Verify seek behavior**

Seek backward into already-captioned audio — captions must appear immediately with no "Preparing…" state. Seek forward two minutes — captions should recover within a few seconds. Seek across a track boundary and confirm captions resume.

- [ ] **Step 6: Verify battery idle**

Leave captions on for ten minutes of playback. Confirm via Xcode's Energy gauge that CPU drops to near-idle once the window is filled, rather than staying pinned.

- [ ] **Step 7: Verify teardown**

Toggle CC off. Confirm CPU returns to baseline and no further `onCaptionSegments` events arrive (check the Xcode console).

- [ ] **Step 8: Verify cache eviction**

Delete the downloaded book. Confirm `captions.json` is gone:

```bash
# With the device connected, via Xcode → Devices and Simulators → Download Container
# Then inspect the item folder for a lingering captions.json
```

- [ ] **Step 9: Record the results**

Append a "Device verification — 2026-07-22" section to the spec at `docs/superpowers/specs/2026-07-22-read-while-listening-captions-design.md` listing each check and its actual result, including any failures. Then commit:

```bash
git add docs/superpowers/specs/2026-07-22-read-while-listening-captions-design.md
git commit -m "docs: record caption device verification results"
```

---

## Deviations from the spec

The spec placed the new Swift files in `ios/App/App/captions/`. This plan instead uses `ios/App/Shared/util/captions/`, because that is where this repo puts pure testable logic (`download/`, `browse/`, `absapi/`) and where the existing test target mirrors its structure at `ios/App/AudiobookshelfUnitTests/Shared/util/`. Only `AbsTranscriber.swift` lives in `ios/App/App/plugins/`, matching the other plugins.
