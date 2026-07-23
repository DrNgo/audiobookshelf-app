# Caption Context Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve caption transcription accuracy by biasing the iOS 26 speech recognizer with a vocabulary of character/place names built (via on-device NER) from the book's and its series siblings' metadata, gathered at download time.

**Architecture:** Web gathers a text corpus (current book + series siblings) on download-complete and hands it to a new `AbsTranscriber.buildContext` plugin method. Native `CaptionContextBuilder` runs `NLTagger` NER + merges structured fields → deduped/capped term list, persisted as `context.json` beside the download (`CaptionContextStore`). At caption-enable, the stored terms are loaded and attached to every transcription window via `AnalysisContext.contextualStrings`.

**Tech Stack:** Swift 5, NaturalLanguage (`NLTagger`), Speech (`SpeechAnalyzer`/`AnalysisContext`, iOS 26), RealmSwift, Capacitor 7, Vue 2 / Nuxt 2, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-22-caption-context-vocabulary-design.md`
**Builds on:** the completed read-while-listening captions feature (same branch, `feat/read-while-listening-captions`).

## Global Constraints

- **iOS 26.0+ only** for the Speech biasing; deployment target stays 14.0. `NLTagger` is iOS 12+ (ungated). Only `SpeechTranscriptionEngine.swift` and `AbsTranscriber.swift` may reference iOS-26 Speech symbols, and only behind the existing `@available`/`#available` gates.
- **No new dependencies** (no SPM/pod/npm). NaturalLanguage and Speech are system frameworks.
- **Additive & non-breaking:** the engine gains ONE optional `contextualStrings: [String]` parameter defaulting to `[]`; empty ⇒ behavior identical to today. All existing caption unit tests must stay green.
- **New downloads only (v1):** no backfill of already-downloaded books.
- **Silent degradation:** missing/failed context never blocks a download, never disturbs playback, never hides the CC button. Absent `context.json` ⇒ run with no bias.
- **Swift source layout:** pure logic in `ios/App/Shared/util/captions/`; plugin in `ios/App/App/plugins/`. Tests mirror at `ios/App/AudiobookshelfUnitTests/Shared/util/captions/`, module `Audiobookshelf`.
- **Web deploy uses `nuxt generate`, NOT `nuxt build`:** Capacitor `webDir` is `dist/`, produced only by `nuxt generate`. After web changes: `npm run generate && npx cap sync ios`, then verify the code landed with `grep -rl <symbol> ios/App/App/public/`.

### Procedure A — Registering a new Swift file with the Xcode targets

App-source files → target **`Audiobookshelf`** (the scheme is `App`, but there is NO target named `App`; targets are `Audiobookshelf`, `AudiobookshelfWidget`, `AudiobookshelfUnitTests`). Test files → **`AudiobookshelfUnitTests`**.

```bash
cd /Users/michaelngo/projects/audiobookshelf-app/ios/App
ruby -e '
require "xcodeproj"
proj = Xcodeproj::Project.open("App.xcodeproj")
path, target_name = ARGV
target = proj.targets.find { |t| t.name == target_name }
group = proj.main_group
path.split("/")[0..-2].each { |part| group = group.find_subpath(part, true) }
ref = group.new_reference(File.expand_path(path))
target.add_file_references([ref])
proj.save
' <RELATIVE_PATH> <TARGET_NAME>
```

`gem install xcodeproj` if missing.

### Procedure B — Committing `project.pbxproj`

`ios/App/App.xcodeproj/project.pbxproj` is `assume-unchanged` (hides a local signing override). A plain `git add` no-ops or leaks the local team. **When a task modifies pbxproj, invoke the `commit-xcodeproj-changes` skill** to commit it — do not plain-`git add` it.

### Running the unit tests

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild test -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AudiobookshelfUnitTests/<TestClassName> 2>&1 | tail -30
```

If `iPhone 17 Pro` is unavailable, pick an available iOS 26 sim from `xcrun simctl list devices available`.

---

## File Structure

**Create:**
- `ios/App/Shared/util/captions/CaptionContextBuilder.swift` — NER + vocabulary policy (corpus → term list)
- `ios/App/Shared/util/captions/CaptionContextStore.swift` — `context.json` persistence
- Test files mirroring both

**Modify:**
- `ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift` — optional `contextualStrings`, attach `AnalysisContext`
- `ios/App/App/plugins/AbsTranscriber.swift` — `buildContext` method; load terms in `enable`
- `plugins/capacitor/AbsTranscriber.js` — `buildContext` wrapper
- A web download-complete handler — gather corpus + call `buildContext` (new mixin/plugin file, see Task 5)

---

### Task 1: CaptionContextBuilder — NER + vocabulary policy

**Files:**
- Create: `ios/App/Shared/util/captions/CaptionContextBuilder.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextBuilderTests.swift`

**Interfaces:**
- Consumes: nothing (uses `NaturalLanguage`)
- Produces: `enum CaptionContextBuilder { static func build(fields: [String], bookBlurb: String, seriesBlurbs: [String], cap: Int = 100) -> [String] }` — returns an ordered, case-insensitively-deduped, capped list of biasing terms; order is current-book names → series-sibling names → structured fields.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextBuilderTests.swift`:

```swift
//
//  CaptionContextBuilderTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionContextBuilderTests: XCTestCase {

    // NER pulls person/place names out of a blurb.
    func testExtractsPersonAndPlaceNamesFromBlurb() {
        let terms = CaptionContextBuilder.build(
            fields: [],
            bookBlurb: "In the city of Luthadel, a street urchin named Vin meets the rebel Kelsier.",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Vin"), "expected person name Vin; got \(terms)")
        XCTAssertTrue(terms.contains("Kelsier"), "expected person name Kelsier; got \(terms)")
        XCTAssertTrue(terms.contains("Luthadel"), "expected place name Luthadel; got \(terms)")
    }

    // Structured fields are always included.
    func testIncludesStructuredFields() {
        let terms = CaptionContextBuilder.build(
            fields: ["Brandon Sanderson", "Michael Kramer"],
            bookBlurb: "",
            seriesBlurbs: []
        )
        XCTAssertTrue(terms.contains("Brandon Sanderson"))
        XCTAssertTrue(terms.contains("Michael Kramer"))
    }

    // Case-insensitive dedupe, first surface form preserved.
    func testDedupesCaseInsensitively() {
        let terms = CaptionContextBuilder.build(
            fields: ["Vin"],
            bookBlurb: "Vin walked. vin ran.",
            seriesBlurbs: []
        )
        XCTAssertEqual(terms.filter { $0.lowercased() == "vin" }.count, 1)
    }

    // Priority: current-book names precede series-sibling names precede fields.
    func testPriorityOrdering() {
        let terms = CaptionContextBuilder.build(
            fields: ["Tor Books"],
            bookBlurb: "Kelsier led the crew.",
            seriesBlurbs: ["The Lord Ruler reigns over the Final Empire."]
        )
        let kelsier = terms.firstIndex(of: "Kelsier")
        let lordRuler = terms.firstIndex { $0.contains("Lord Ruler") }
        let tor = terms.firstIndex(of: "Tor Books")
        XCTAssertNotNil(kelsier); XCTAssertNotNil(tor)
        if let k = kelsier, let t = tor { XCTAssertLessThan(k, t, "current-book name before field") }
        if let l = lordRuler, let t = tor { XCTAssertLessThan(l, t, "sibling name before field") }
    }

    // Cap keeps the highest-priority terms.
    func testCapIsEnforcedKeepingHighestPriority() {
        let manyFields = (0..<200).map { "Field\($0)" }
        let terms = CaptionContextBuilder.build(
            fields: manyFields,
            bookBlurb: "Kelsier stood.",
            seriesBlurbs: [],
            cap: 10
        )
        XCTAssertLessThanOrEqual(terms.count, 10)
        XCTAssertEqual(terms.first, "Kelsier", "current-book name survives the cap first")
    }

    // Empty corpus → fields only, no crash.
    func testEmptyCorpusReturnsFieldsOnly() {
        let terms = CaptionContextBuilder.build(fields: ["Author Name"], bookBlurb: "", seriesBlurbs: [])
        XCTAssertEqual(terms, ["Author Name"])
    }

    func testEverythingEmptyReturnsEmpty() {
        XCTAssertEqual(CaptionContextBuilder.build(fields: [], bookBlurb: "", seriesBlurbs: []), [])
    }
}
```

- [ ] **Step 2: Register the test file**

Follow **Procedure A** with `AudiobookshelfUnitTests/Shared/util/captions/CaptionContextBuilderTests.swift` and target `AudiobookshelfUnitTests`.

- [ ] **Step 3: Run the test to verify it fails**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionContextBuilderTests`.
Expected: compile failure, "cannot find 'CaptionContextBuilder' in scope".

- [ ] **Step 4: Implement the builder**

Create `ios/App/Shared/util/captions/CaptionContextBuilder.swift`:

```swift
//
//  CaptionContextBuilder.swift
//  Audiobookshelf
//
//  Turns a book's (and its series siblings') metadata into a biasing vocabulary
//  for the speech recognizer. On-device NER (NLTagger) pulls the proper nouns ASR
//  mangles — character and place names — out of the blurbs; structured fields
//  (author/narrator/series/title) are merged in. Deduped, priority-ordered, capped.
//
//  No Speech / iOS-26 symbols here — this is version-agnostic and unit-tested.
//

import Foundation
import NaturalLanguage

enum CaptionContextBuilder {

    /// Build the ordered, deduped, capped biasing term list.
    /// Order: current-book names → series-sibling names → structured fields.
    static func build(fields: [String],
                      bookBlurb: String,
                      seriesBlurbs: [String],
                      cap: Int = 100) -> [String] {
        var ordered: [String] = []
        ordered.append(contentsOf: names(in: bookBlurb))          // current-book names first
        for blurb in seriesBlurbs { ordered.append(contentsOf: names(in: blurb)) }
        ordered.append(contentsOf: fields)                        // structured fields last

        // Case-insensitive dedupe preserving first-seen surface form.
        var seen = Set<String>()
        var result: [String] = []
        for term in ordered {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { result.append(trimmed) }
            if result.count >= cap { break }
        }
        return result
    }

    /// Person / place / organization names in `text`, in order of appearance.
    private static func names(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        var found: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: options) { tag, range in
            if let tag = tag, wanted.contains(tag) {
                found.append(String(text[range]))
            }
            return true
        }
        return found
    }
}
```

- [ ] **Step 5: Register the source file**

Follow **Procedure A** with `Shared/util/captions/CaptionContextBuilder.swift` and target `Audiobookshelf`.

- [ ] **Step 6: Run the tests to verify they pass**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionContextBuilderTests`.
Expected: `** TEST SUCCEEDED **`, 7 tests passing.

If a name test fails, `NLTagger` may tokenize a name differently than expected on this OS build — adjust the test's expected surface forms to what the tagger actually returns (log `terms`), keeping the dedupe/priority/cap assertions intact. NER surface forms are the SDK's call, not ours.

- [ ] **Step 7: Commit**

Use **Procedure B** (`commit-xcodeproj-changes` skill), including:
```
ios/App/Shared/util/captions/CaptionContextBuilder.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextBuilderTests.swift
ios/App/App.xcodeproj/project.pbxproj
```
Message: `feat(ios): NER-based caption context vocabulary builder`

---

### Task 2: CaptionContextStore — persistence

**Files:**
- Create: `ios/App/Shared/util/captions/CaptionContextStore.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextStoreTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `final class CaptionContextStore { init(directory: URL); func save(_ terms: [String]) throws; func load() -> [String]; func evict() }`. `load()` returns `[]` on missing/corrupt/version-mismatch — never throws. Stores `context.json` in `directory`.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextStoreTests.swift`:

```swift
//
//  CaptionContextStoreTests.swift
//  AudiobookshelfUnitTests
//

import XCTest
@testable import Audiobookshelf

final class CaptionContextStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLoadOnMissingFileReturnsEmpty() {
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["Vin", "Kelsier", "Luthadel"])
        XCTAssertEqual(store.load(), ["Vin", "Kelsier", "Luthadel"])
    }

    func testSaveOverwrites() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["A"])
        try store.save(["B", "C"])
        XCTAssertEqual(store.load(), ["B", "C"])
    }

    func testCorruptFileReturnsEmpty() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("context.json"))
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testWrongSchemaVersionReturnsEmpty() throws {
        let json = #"{"version": 999, "terms": ["X"]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("context.json"))
        XCTAssertEqual(CaptionContextStore(directory: dir).load(), [])
    }

    func testEvictRemovesFile() throws {
        let store = CaptionContextStore(directory: dir)
        try store.save(["A"])
        store.evict()
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("context.json").path))
    }
}
```

- [ ] **Step 2: Register the test file**

Follow **Procedure A** with `AudiobookshelfUnitTests/Shared/util/captions/CaptionContextStoreTests.swift` and target `AudiobookshelfUnitTests`.

- [ ] **Step 3: Run the test to verify it fails**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionContextStoreTests`.
Expected: compile failure, "cannot find 'CaptionContextStore' in scope".

- [ ] **Step 4: Implement the store**

Create `ios/App/Shared/util/captions/CaptionContextStore.swift`:

```swift
//
//  CaptionContextStore.swift
//  Audiobookshelf
//
//  Persists the biasing vocabulary as context.json inside the item's download
//  folder, so it is evicted with the download (mirrors CaptionStore). load()
//  never throws — a missing/corrupt/stale file degrades to no bias.
//

import Foundation

final class CaptionContextStore {

    private static let schemaVersion = 1
    private static let filename = "context.json"

    private struct Payload: Codable {
        let version: Int
        let terms: [String]
    }

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    init(directory: URL) { self.directory = directory }

    func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.schemaVersion
        else { return [] }
        return payload.terms
    }

    func save(_ terms: [String]) throws {
        let payload = Payload(version: Self.schemaVersion, terms: terms)
        let data = try JSONEncoder().encode(payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    func evict() { try? FileManager.default.removeItem(at: fileURL) }
}
```

- [ ] **Step 5: Register the source file**

Follow **Procedure A** with `Shared/util/captions/CaptionContextStore.swift` and target `Audiobookshelf`.

- [ ] **Step 6: Run the tests to verify they pass**

Run with `-only-testing:AudiobookshelfUnitTests/CaptionContextStoreTests`.
Expected: `** TEST SUCCEEDED **`, 6 tests passing.

- [ ] **Step 7: Commit**

Use **Procedure B** (`commit-xcodeproj-changes` skill), including:
```
ios/App/Shared/util/captions/CaptionContextStore.swift
ios/App/AudiobookshelfUnitTests/Shared/util/captions/CaptionContextStoreTests.swift
ios/App/App.xcodeproj/project.pbxproj
```
Message: `feat(ios): context.json store for caption biasing vocabulary`

---

### Task 3: Attach contextualStrings to the transcription engine

**Files:**
- Modify: `ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift`

**Interfaces:**
- Consumes: nothing new
- Produces: `SpeechTranscriptionEngine.init(locale: Locale, contextualStrings: [String] = [])`; when non-empty, each transcription window attaches the terms as `AnalysisContext.contextualStrings[.general]` via `analyzer.setContext(_:)`.

**Verified SDK (Apple docs, iOS 26):** `SpeechAnalyzer.setContext(_ newContext: AnalysisContext) async throws`; `AnalysisContext.contextualStrings` is `[ContextualStringsTag: [String]] { get set }`; `AnalysisContext.ContextualStringsTag` has a predefined `.general` and `init(_:)`. Confirm these compile against the installed SDK before proceeding (⇧⌘O in Xcode).

- [ ] **Step 1: Add the stored property and initializer parameter**

In `SpeechTranscriptionEngine.swift`, change the stored `locale` region and init. Current:
```swift
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }
```
Replace with:
```swift
    private let locale: Locale
    /// Optional biasing vocabulary (character/place names from book+series
    /// metadata). Empty ⇒ no bias, identical to the unbiased path.
    private let contextualStrings: [String]

    init(locale: Locale, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }
```

- [ ] **Step 2: Attach the context before starting analysis**

In `run(...)`, find where the analyzer is created and started:
```swift
        let analyzer = SpeechAnalyzer(modules: [transcriber])
```
and the later:
```swift
                try await analyzer.start(inputSequence: inputStream)
```
Between the analyzer creation and `start(inputSequence:)` (inside the `withTaskCancellationHandler` body, before `start`), attach the context:
```swift
                // Bias recognition toward the book's known names, if we have any.
                if !self.contextualStrings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = self.contextualStrings
                    try await analyzer.setContext(context)
                }
                try await analyzer.start(inputSequence: inputStream)
```
(Place the `setContext` call inside the same `do` block as `start`, so a thrown error is handled by the existing `catch` that finishes input + cancels the results task.)

- [ ] **Step 3: Build to verify it compiles**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild build -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If `.general` / `setContext` / `contextualStrings` mismatch the SDK, correct against the real declarations (⇧⌘O) — the structure is right; a selector may differ.

- [ ] **Step 4: Verify existing caption tests still pass**

```bash
xcodebuild test -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AudiobookshelfUnitTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (engine E2E tests skip in-sim, as before). The engine change is additive; nothing should regress.

- [ ] **Step 5: Commit**

```bash
git add ios/App/Shared/util/captions/SpeechTranscriptionEngine.swift
git commit -m "feat(ios): attach contextualStrings bias to the speech analyzer"
```

---

### Task 4: `AbsTranscriber.buildContext` + load terms on enable

**Files:**
- Modify: `ios/App/App/plugins/AbsTranscriber.swift`

**Interfaces:**
- Consumes: `CaptionContextBuilder.build(fields:bookBlurb:seriesBlurbs:cap:)`, `CaptionContextStore`, `SpeechTranscriptionEngine.init(locale:contextualStrings:)`
- Produces, on the JS side: `AbsTranscriber.buildContext({ libraryItemId: string, fields: string[], bookBlurb: string, seriesBlurbs: string[] }) -> { termCount: number }`.

- [ ] **Step 1: Register the method**

In the `pluginMethods` array in `AbsTranscriber.swift`, add:
```swift
        CAPPluginMethod(name: "buildContext", returnType: CAPPluginReturnPromise),
```

- [ ] **Step 2: Add a download-folder resolver helper**

`enable()` already resolves a `LocalLibraryItem` into a scheduler `Context` (with a `directory`). Add a small shared resolver for the item's download folder so `buildContext` can reuse it. Add this method to `AbsTranscriber`:
```swift
    /// The download folder for a library item id (server or local id), or nil
    /// if the item isn't a downloaded book.
    private func downloadDirectory(for libraryItemId: String) -> URL? {
        let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: libraryItemId)
            ?? Database.shared.getLocalLibraryItem(localLibraryItemId: libraryItemId)
        guard let item = item, item.isBook else { return nil }
        return item.contentDirectory
    }
```
(If `enable`'s existing context builder already computes `contentDirectory`, leave it as-is — this helper is only for `buildContext`. Do not refactor `enable` in this task.)

- [ ] **Step 3: Implement `buildContext`**

Add to `AbsTranscriber.swift`:
```swift
    @objc func buildContext(_ call: CAPPluginCall) {
        guard let libraryItemId = call.getString("libraryItemId") else {
            call.reject("libraryItemId is required")
            return
        }
        let fields = call.getArray("fields", String.self) ?? []
        let bookBlurb = call.getString("bookBlurb") ?? ""
        let seriesBlurbs = call.getArray("seriesBlurbs", String.self) ?? []

        // Off the main thread — NER over several blurbs is CPU work.
        DispatchQueue.global(qos: .utility).async {
            guard let directory = self.downloadDirectory(for: libraryItemId) else {
                // Not a downloaded book (or gone) — nothing to store; not an error.
                call.resolve(["termCount": 0])
                return
            }
            let terms = CaptionContextBuilder.build(fields: fields, bookBlurb: bookBlurb, seriesBlurbs: seriesBlurbs)
            do {
                try CaptionContextStore(directory: directory).save(terms)
            } catch {
                AppLogger(category: "AbsTranscriber").error("Failed to write caption context: \(error)")
                call.resolve(["termCount": 0])
                return
            }
            call.resolve(["termCount": terms.count])
        }
    }
```
(`call.getArray(_:String.self)` is the Capacitor accessor for a JS string array. Confirm the exact accessor name against the Capacitor version if the build complains — it may be `call.getArray("fields")` returning `[JSValue]` needing a `compactMap { $0 as? String }`.)

- [ ] **Step 4: Load terms and pass them to the engine in `enable`**

In `enable()`, find where the engine is constructed:
```swift
            let engine = SpeechTranscriptionEngine(locale: resolved)
```
Replace with a version that loads the stored terms from the same item's download folder:
```swift
            // Load the biasing vocabulary built at download time (empty if none).
            let contextTerms = context.directory.map { CaptionContextStore(directory: $0).load() } ?? []
            let engine = SpeechTranscriptionEngine(locale: resolved, contextualStrings: contextTerms)
```
**Verify the local variable name for the scheduler context's download folder.** In the current `enable`, the resolved item context exposes its folder — confirm the exact property (it may be `context.directory`, or you may need to call the new `downloadDirectory(for: libraryItemId)` helper instead). Use whichever the current code exposes; if unclear, use `self.downloadDirectory(for: libraryItemId)` which is unambiguous:
```swift
            let contextDir = self.downloadDirectory(for: libraryItemId)
            let contextTerms = contextDir.map { CaptionContextStore(directory: $0).load() } ?? []
            let engine = SpeechTranscriptionEngine(locale: resolved, contextualStrings: contextTerms)
```

- [ ] **Step 5: Build and run the unit suite**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
xcodebuild build -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
xcodebuild test -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AudiobookshelfUnitTests 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/App/App/plugins/AbsTranscriber.swift
git commit -m "feat(ios): AbsTranscriber.buildContext + load biasing terms on enable"
```

---

### Task 5: JS wrapper + web corpus gathering on download-complete

**Files:**
- Modify: `plugins/capacitor/AbsTranscriber.js`
- Create: `plugins/captionContext.client.js` (Nuxt client plugin that listens for download-complete)
- Reference (existing event source): `components/widgets/DownloadProgressIndicator.vue:90` uses `AbsDownloader.addListener('onItemDownloadComplete', ...)`

**Interfaces:**
- Consumes: `AbsTranscriber.buildContext(...)` (Task 4); server REST via `this.$nativeHttp` / `app.$nativeHttp`
- Produces: on each `onItemDownloadComplete` (new downloads), gathers the corpus and calls `buildContext`.

- [ ] **Step 1: Add `buildContext` to the JS wrapper**

In `plugins/capacitor/AbsTranscriber.js`, add to the web stub class:
```js
  async buildContext() { return { termCount: 0 } }
```
(The `registerPlugin('AbsTranscriber', ...)` proxy exposes the native method automatically; the stub only affects web/`$platform !== 'ios'`.)

- [ ] **Step 2: Write the download-complete handler**

Create `plugins/captionContext.client.js`:

```js
// Builds the caption biasing vocabulary when a book finishes downloading (iOS).
// New downloads only; best-effort — offline or a fetch failure degrades to
// current-book context (or none), never blocking anything.
import { AbsDownloader, AbsTranscriber } from '@/plugins/capacitor'

const MAX_SERIES_SIBLINGS = 12

export default function ({ $platform, $nativeHttp }) {
  if ($platform !== 'ios') return

  const gatherAndBuild = async (data) => {
    try {
      const serverItemId = data?.libraryItem?.libraryItemId || data?.libraryItem?.id || data?.localLibraryItem?.libraryItemId
      const localItemId = data?.localLibraryItem?.id || data?.libraryItem?.id
      if (!localItemId) return

      // Full metadata for the current book (description, series, authors, narrators).
      let item = null
      if (serverItemId) {
        item = await $nativeHttp.get(`/api/items/${serverItemId}?expanded=1`).catch(() => null)
      }
      const md = item?.media?.metadata || data?.libraryItem?.media?.metadata || {}

      const fields = []
      if (md.title) fields.push(md.title)
      if (md.subtitle) fields.push(md.subtitle)
      ;(md.authors || []).forEach((a) => a?.name && fields.push(a.name))
      if (md.authorName) fields.push(md.authorName)
      ;(md.narrators || []).forEach((n) => n && fields.push(n))
      ;(md.series || []).forEach((s) => s?.name && fields.push(s.name))

      const bookBlurb = md.description || md.desc || ''

      // Series siblings' blurbs (best-effort).
      const seriesBlurbs = []
      const libraryId = item?.libraryId || data?.libraryItem?.libraryId
      const firstSeries = (md.series || [])[0]
      if (serverItemId && libraryId && firstSeries?.id) {
        const encoded = typeof btoa === 'function' ? btoa(`series.${firstSeries.id}`) : ''
        const res = await $nativeHttp
          .get(`/api/libraries/${libraryId}/items?filter=${encoded}&limit=${MAX_SERIES_SIBLINGS}&expanded=1`)
          .catch(() => null)
        const siblings = res?.results || res?.libraryItems || []
        for (const sib of siblings) {
          const sid = sib?.id
          if (!sid || sid === serverItemId) continue
          const desc = sib?.media?.metadata?.description || sib?.media?.metadata?.desc
          if (desc) seriesBlurbs.push(desc)
        }
      }

      await AbsTranscriber.buildContext({ libraryItemId: localItemId, fields, bookBlurb, seriesBlurbs })
    } catch (e) {
      console.warn('[captionContext] build failed (non-fatal)', e)
    }
  }

  AbsDownloader.addListener('onItemDownloadComplete', (data) => {
    if (data?.localMediaProgress || data?.localLibraryItem) gatherAndBuild(data)
  })
}
```

**Verify against the running server / actual event payload (do this in Step 4 on device, and adjust):**
- The exact shape of `onItemDownloadComplete`'s `data` (which id fields it carries) — log it and map `serverItemId`/`localItemId` accordingly.
- The series-items endpoint + filter format. AudiobookshelfServer filters library items by `filter=<base64("series.<seriesId>")>`. If the response shape or filter differs on the target server version, adjust the URL and the `results`/`libraryItems` extraction. If sibling descriptions aren't in the list response, fetch each sibling `GET /api/items/:id?expanded=1` (capped at `MAX_SERIES_SIBLINGS`).
- If `md.series` isn't present on the expanded item, series enrichment is simply skipped (current-book context still built).

- [ ] **Step 3: Register the Nuxt plugin**

In `nuxt.config.js`, add to the `plugins` array, **after** the `nativeHttp` plugin entry (it depends on `$nativeHttp` being injected first):
```js
    { src: '~/plugins/captionContext.client.js', mode: 'client' },
```
Confirm the existing `plugins:` array style and match it. If `$nativeHttp` isn't available via context destructuring in this Nuxt setup, access it through the injected app instead (match how other client plugins read it).

- [ ] **Step 4: Build the web layer, sync, and verify it landed**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
npm run generate && npx cap sync ios 2>&1 | tail -8
grep -rl "captionContext\|buildContext" ios/App/App/public/ | head
```
Expected: generate + sync succeed; the grep returns at least one `ios/App/App/public/_nuxt/*.js` match (proves the new plugin code deployed — a build passing is NOT sufficient, per Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add plugins/capacitor/AbsTranscriber.js plugins/captionContext.client.js nuxt.config.js
git commit -m "feat: gather book+series corpus on download and build caption context"
```

---

### Task 6: Device verification

**Files:** none unless a defect is found.

Runs on the physical iOS 26 device (the sim has no speech model, and accuracy is the whole point). Deploy first:
```bash
cd /Users/michaelngo/projects/audiobookshelf-app
npm run generate && npx cap sync ios
```
then build/run to the device from Xcode (or the run tooling).

- [ ] **Step 1: Verify `context.json` is written on download**

Download a book that is **part of a series** and has a **rich description with character/place names** (fantasy/sci-fi is ideal). Then confirm the context file exists and is sensible — via Xcode → Devices → download the app container, and inspect the item's folder for `context.json`; confirm it holds a list of the book's actual character/place names. Record the term list.

- [ ] **Step 2: Verify accuracy improvement (the core check)**

Play the downloaded book, enable captions, and listen through a passage that names characters/places. Confirm those names are now transcribed correctly (or closer) than before this feature. Compare against a book with NO `context.json` (e.g. one downloaded before this feature) to sanity-check the difference. Record specific names that improved.

- [ ] **Step 3: Verify no regression + graceful degradation**

- A **non-series** book still downloads and captions work (context = current-book only).
- A book downloaded **offline** (or with the server unreachable at download) still captions — context is current-book-only or empty, no error, no blocked download.
- Captions on a book with an **empty/missing** `context.json` behave exactly as before (no crash, no missing button).

- [ ] **Step 4: Record results**

Append a "Context-vocabulary device verification — 2026-07-22" section to the spec (`docs/superpowers/specs/2026-07-22-caption-context-vocabulary-design.md`) with each check, the observed term list, and specific name improvements (or lack thereof — if biasing didn't visibly help, note it; the cap or extraction may need tuning). Commit:
```bash
git add docs/superpowers/specs/2026-07-22-caption-context-vocabulary-design.md
git commit -m "docs: record caption context device verification"
```

---

## Notes on deviations / open verifications

- **Series-items endpoint (Task 5)** is specified as the Audiobookshelf `filter=base64("series.<id>")` library-items query, to be confirmed against the target server in Step 4; sibling-description fallback (fetch each expanded, capped) is provided.
- **`ContextualStringsTag.general` / `setContext` (Task 3)** are from Apple's docs; confirmed against the SDK at build time like the original captions engine's `audioTimeRange`.
- **Cap = 100** is a starting default (Global Constraints); Task 6 may recommend tuning.
