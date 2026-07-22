# Read While Listening — On-Device Live Captions (iOS)

**Date:** 2026-07-22
**Status:** Design approved; implementation plan written and revised after external (Codex) review. See `docs/superpowers/plans/2026-07-22-read-while-listening-captions.md`.
**Platform:** iOS 26+ only

## Goal

Let a listener read along with a downloaded audiobook. Captions are generated
on-device by speech recognition, run slightly ahead of the playhead, and
highlight the current word in sync with the audio.

## Scope decisions

These were settled during brainstorming. Each rules out a materially different
product, so they are recorded with the alternative that was rejected.

| Decision | Chosen | Rejected alternative |
|---|---|---|
| Text source | ASR transcription of the audio | Forced-alignment of an existing epub (better text, but requires owning the ebook); dual ebook+ASR pipeline (two full systems) |
| Presentation | Rolling captions, no scrollback | Full transcript reading view |
| Platforms | iOS only | Android needs a bundled Whisper/Vosk model — no system long-form ASR API |
| Sync model | Run ahead of the playhead on the downloaded file | Live tap on player output (trails audio ~1–2s, visibly rewrites text, breaks at 2x and on seek) |
| Persistence | Cache timed segments per book, evicted with the download | Memory-only (re-decodes on every seek/restart) |
| UI placement | Caption panel replaces cover art, toggled by a CC button | Fixed strip below cover (too small); separate full-screen route (bigger build) |
| Work scope | Sliding window while captions are visible | Whole-track burst; whole-book background pass |
| Recognizer | `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+) | `SFSpeechRecognizer` (works on the current iOS 14 target, but ~1-min request limit forces chunk-stitching and worse accuracy on a deprecated path); bundled `whisper.cpp` (75–150MB, slower, large integration effort) |

**No fallback recognizer ships in v1.** On iOS < 26 the feature is absent
rather than degraded.

## Verified constraints

Established by reading the codebase and the platform docs, not assumed:

- `LocalFile.contentPath` and `AudioTrack.startOffset` / `localFileId` already
  provide everything needed to map book time to a file and offset. No new
  download plumbing.
- `components/app/AudioPlayer.vue:673` polls `AbsAudioPlayer.getCurrentTime()`
  on a **1000ms** interval. Too coarse for word highlighting — the caption
  clock must interpolate (see below).
- iOS deployment target is currently **13.0 / 14.0** (`ios/App/Podfile`: 14.0).
  The feature is therefore gated at runtime, not by raising the target.
- `SpeechTranscriber` accepts `attributeOptions: [.audioTimeRange]`, which
  yields time-coded runs in the result `AttributedString` — this supplies word
  timing directly.
- It is on-device only, but still requires `NSSpeechRecognitionUsageDescription`
  in Info.plist, a `requestAuthorization` prompt, and a one-time language model
  download via `AssetInventory`.
- Plugin conventions: `CAPBridgedPlugin` Swift classes in
  `ios/App/App/plugins/`, thin JS wrappers in `plugins/capacitor/` exported
  from `index.js`.
- Test infrastructure: `AudiobookshelfUnitTests` target exists. There is **no
  JavaScript test infrastructure** (no jest, no vitest).

## Architecture

New Swift files live in `ios/App/App/captions/`, following the existing
`carplay/`, `widget/`, and `shortcuts/` grouping.

> **Implementation note:** the plan supersedes this location. Pure, testable
> logic (models, timeline, store, scheduler, engine) lives in
> `ios/App/Shared/util/captions/` — where this repo keeps its other unit-tested
> logic (`download/`, `browse/`) and where the `AudiobookshelfUnitTests` target
> mirrors the structure — while only `AbsTranscriber.swift` sits in
> `ios/App/App/plugins/` with the other plugins. The paths in sections 1–3 below
> reflect the original spec; follow the plan's paths when building.

Five units. The two boundaries that matter: the scheduler never references
`SpeechTranscriber` types, and the engine never references Realm.

The scheduler depends on a `SegmentProducing` protocol, not on
`TranscriptionEngine` directly. `AbsTranscriber` performs the single
`if #available(iOS 26, *)` check when constructing the concrete engine, so the
availability gate exists in exactly one place and the scheduler compiles and
tests without any iOS 26 symbol. This is also what makes the fake-engine unit
tests possible.

### 1. `ios/App/App/captions/TranscriptionEngine.swift` (new)

Pure speech recognition. Knows nothing about audiobooks.

- **Interface:** given a file URL, a start offset, and a duration, return an
  async stream of timed segments.
- **Internals:** `AVAssetReader` → `AVAudioConverter` → `SpeechTranscriber`.
  `AVAssetReader` rather than `AVAudioFile`, which is unreliable on `.m4b`.
- Owns authorization and `AssetInventory` model installation.
- `@available(iOS 26, *)`.

### 2. `ios/App/App/captions/CaptionStore.swift` (new)

Persistence only.

- **Interface:** read, write, and evict segments for a `libraryItemId`.
- One `captions.json` per item inside the existing download folder via
  `AbsDownloader.itemDownloadFolder`, so deleting a download deletes its
  captions with no extra wiring.
- Records schema version and the locale used, for invalidation.

### 3. `ios/App/App/captions/CaptionScheduler.swift` (new)

The sliding-window brain, and the only unit aware of audiobook structure.

- Owns book-time → (track, file, offset) mapping via `AudioTrack.startOffset`
  and `localFileId`.
- Queries the store first, calls the engine only for gaps.
- Cancels in-flight work on seek or disable.

### 4. `ios/App/App/plugins/AbsTranscriber.swift` (new) + `plugins/capacitor/AbsTranscriber.js`

Capacitor surface, nothing more.

- **Methods:** `enable`, `updateTime`, `disable`, `isSupported`
- **Events:** `onCaptionSegments`, `onCaptionStatus`

(`updateTime` replaced the originally-planned `getSegments`: segments are pushed
to the WebView via the `onCaptionSegments` event, so a pull method is unused,
while the plugin does need per-tick playhead updates to advance/seek the window.)

### 5. `components/player/CaptionPanel.vue` (new)

Rendering and the caption clock. `AudioPlayer.vue` gains only a CC button and a
conditional swap of the cover-art block — its footprint in that 44KB file stays
minimal. Clock math and segment lookup live in a pure `utils/captionClock.js`.

## Data flow

**Enable.** CC tap → `CaptionPanel` mounts → `AbsTranscriber.enable({ libraryItemId, currentTime })`
→ scheduler loads the `LocalLibraryItem`, builds the track table, and queries
`CaptionStore`. Cached coverage is emitted immediately in one batch, so
re-listening or seeking backward paints instantly.

**Fill.** For the uncovered part of the window the scheduler starts **one
continuous engine job**, not a series of fixed chunks: it opens the track file
at the correct offset and feeds `SpeechTranscriber` until the window is full,
the track ends, or the job is cancelled. Discrete chunks would cut words at
every seam; a continuous sequence produces seams only at genuine track
boundaries and seek points. Finalized results arrive carrying `.audioTimeRange`;
the scheduler adds `track.startOffset` to convert file-relative to book time,
appends to the store, and emits batches as they finalize.

**Volatile results are disabled.** Because transcription runs ahead of the
playhead, provisional guesses are never needed — only finalized text is emitted.
This is what removes the self-rewriting-sentence problem inherent to a live tap.

**Window policy.** Maintain ~10 minutes decoded ahead; refill when the margin
drops below 5 minutes. Exactly one engine job at a time. Once the window is
full the scheduler idles with no CPU use, regardless of playback state.

**The caption clock.** `CaptionPanel` treats each 1s native sample as an anchor:
`{ bookTime, wallClock: performance.now(), rate, isPlaying }`. A
`requestAnimationFrame` loop estimates `bookTime + elapsed × rate` and
binary-searches the segment list for the active word. Every poll re-anchors,
bounding drift to well under the poll interval. Pause, rate change, and seek
re-anchor immediately. No additional bridge traffic; remains smooth at 2x.

**Seek.** Cancels the in-flight engine job, re-anchors the clock, re-queries the
cache, and starts a fresh job at the new position. Backward seeks into
already-transcribed audio cost nothing.

**Disable / unmount.** Cancels all work and releases the analyzer. Captions
never run while the panel is not visible — this is the entire battery story.

## Error handling and edge cases

The CC button reflects real capability in every state:

| Condition | Behavior |
|---|---|
| iOS < 26 | `isSupported()` returns false; CC button not rendered |
| Book not downloaded | CC button rendered but disabled: "Captions require a downloaded book." |
| Speech permission denied | Panel explains and links to Settings |
| Language model not installed | "Downloading language support…" state driven by `AssetInventory`; requires network, fails gracefully offline |
| Locale unsupported | "Captions aren't available for this language." |
| Track file missing or corrupt | Log via `AbsLogger`, emit error status, disable cleanly — never disrupt playback |

**Language selection.** v1 uses the device locale. A per-book override is a
plausible follow-on but speculative until a real mismatch appears. The cache
records its locale, so a device language change invalidates rather than silently
serving mismatched text.

**Content scope.** Audiobooks only. Podcasts use a separate model
(`LocalPodcastEpisode`) and would roughly double the paths to test.

**Backgrounding.** The scheduler suspends on background and resumes on
foreground. It never requests background execution time.

**Memory.** The JS side holds a ±30 minute window of segments and prunes
outside it, so long sessions cannot accumulate a whole book's text in the
WebView.

## Accuracy expectations

Narrated audiobooks are clean studio speech, so results on ordinary prose should
be good. Proper nouns and invented names — fantasy and science fiction
especially — will be wrong and will stay wrong, because there is no book text to
correct against. This is inherent to the ASR-only approach and should be
communicated in the feature's first-run copy.

## Testing strategy

- **Swift unit tests — `CaptionScheduler`** against a fake engine and in-memory
  store: book-time ↔ track/offset mapping across multi-track boundaries, gap
  detection, window refill arithmetic, cancel-on-seek. This is pure logic and
  where the real bugs will be.
- **Swift unit test — `CaptionStore`**: round-trip, plus invalidation on locale
  and schema version change.
- **Integration test — `TranscriptionEngine`** against a short bundled audio
  fixture, gated to iOS 26.
- **JavaScript:** clock math and segment lookup are isolated in a pure
  `utils/captionClock.js` with no Vue or plugin dependency, so they are
  inspectable now and testable if JS test infrastructure is added later.
  Adding that infrastructure is explicitly out of scope for this feature.
- **Manual device pass (required):** simulator speech-model availability is
  unreliable. Verify on hardware: first-run permission, model download, sync at
  1x and 2x, seek behavior, and track-boundary seams.

## Out of scope

- Android implementation
- Ebook/audio forced alignment
- Podcast episodes
- Per-book language override
- Transcript scrollback, search, or export
- JavaScript test infrastructure
- Raising the iOS deployment target
