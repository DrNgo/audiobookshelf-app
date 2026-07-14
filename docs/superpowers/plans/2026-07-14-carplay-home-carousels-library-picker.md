# CarPlay Home Carousels + Home Library Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CarPlay Library tab with a library-picker button in Home's top bar (Home becomes the root, tab bar removed), and render each Home shelf as a horizontal cover carousel with per-cover titles.

**Architecture:** `CarPlayManager` builds the Home `CPListTemplate` as the CarPlay root with a trailing nav-bar button that pushes `CarPlayLibraryController`'s picker template. Home's three shelves each become one `CPListImageRowItem` (a horizontal cover carousel) built through a single version-laddered helper. Covers are loaded through the existing sized-cover `NSCache`; browse data still flows through `BrowseApi`/`BrowseCache`.

**Tech Stack:** Swift, CarPlay framework (`CPListImageRowItem`, `CPListImageRowItemRowElement`, `CPBarButton`), Xcode 26.5 SDK, iOS deployment target 13/14.

## Global Constraints

- Branch `feat/sdk-browse-endpoints`; every commit must stay upstream-mergeable (no local `DEVELOPMENT_TEAM = NG5DZJG8LP` / `com.audiobookshelfngo.app` leak).
- **App target minimum is iOS 14.0** (the wider project floor is 13.0 for other targets, but the `Audiobookshelf` app target — which owns all CarPlay code — is 14.0). All CarPlay APIs used here are iOS 14+, so no iOS-13 guard is needed; the ladder is only for the newer per-cover-title APIs. Ladder: iOS 26+ `CPListImageRowItem(text:elements:allowsMultipleLines:)`; iOS 17.4–25.x `CPListImageRowItem(text:images:imageTitles:)`; iOS 14–17.3 `CPListImageRowItem(text:images:)` (no per-cover titles).
- **Main-actor rule:** every CarPlay template object (`CPListImageRowItem`, `CPListImageRowItemRowElement`, `CPListTemplate`, `CPBarButton`) and `CPInterfaceController` (incl. `carTraitCollection`) is main-thread-only. Construct/mutate them on the main actor; only network/cover *fetching* runs off-main.
- **Carousel cover sizing:** size carousel covers to the *image-row* max, not the list-item max — `CPListImageRowItemRowElement.maximumImageSize` on iOS 26+, else `CPListImageRowItem.maximumImageSize` (NOT `CPListItem.maximumImageSize`), at `interfaceController.carTraitCollection.displayScale`.
- New Swift files must be registered into the `Audiobookshelf` target via the `xcodeproj` gem and committed with the **commit-xcodeproj-changes** skill (project.pbxproj is `assume-unchanged`). Existing-file edits commit normally.
- Books only. Playback via `BrowsePlaybackStarter.play(item) { push CPNowPlayingTemplate.shared }`. Reuse `BrowseCache` (browse data) and the sized-cover `NSCache` in `CarPlayManager` (covers).
- Per-cover text = **book title only**. Library button = `books.vertical` SF Symbol icon; current library name shown in the Recently Added shelf header ("Recently Added · <Library>").
- Cap each carousel to `CPMaximumNumberOfGridImages` (`items.prefix(...)`).
- CarPlay template UI cannot be unit-tested; verify those pieces **behaviorally on the CarPlay simulator** (I/O → External Displays → CarPlay). Keep all existing unit tests green.
- Build/run each task with: `mcp__xcode__build_run_sim` (defaults already set: workspace `ios/App/App.xcworkspace`, scheme `App`, sim `5D3E4DBF-BE38-4CD3-925E-692CAFDCCAA5`, bundle `com.audiobookshelfngo.app.dev`).

---

### Task 1: Home as root + library-picker button (remove tab bar)

Turn the Library tab into a pushed picker reached from a Home nav-bar button; make Home the CarPlay root. Home shelves stay the current vertical list in this task (carousels come in Task 3). Also lands the already-written active-library checkmark.

**Files:**
- Modify: `ios/App/App/carplay/CarPlayManager.swift` (`start()`, `refresh()`, remove `CPTabBarTemplateDelegate`, add `presentLibraryPicker()`)
- Modify: `ios/App/App/carplay/CarPlayLibraryController.swift` (pop after select; checkmark already present, uncommitted)

**Interfaces:**
- Consumes: `CarPlayManager.interfaceController: CPInterfaceController`, `CarPlayManager.rebuildHome()`, `CarPlayManager.activeLibraryId`, `CarPlayLibraryController.template: CPListTemplate`, `CarPlayLibraryController.reload()`.
- Produces: `CarPlayManager.presentLibraryPicker()` (pushes the picker); `CarPlayLibraryController` selecting a row pops back to Home.

- [ ] **Step 1: Make Home the root and add the library button.** In `CarPlayManager.swift`, delete the `tabBar` property, the `CPTabBarTemplate` usage, and the `CPTabBarTemplateDelegate` extension. Replace `start()` with:

```swift
func start() {
    let library = CarPlayLibraryController(manager: self)
    self.libraryController = library

    homeTemplate.trailingNavigationBarButtons = [
        CPBarButton(image: UIImage(systemName: "books.vertical") ?? UIImage()) { [weak self] _ in
            self?.presentLibraryPicker()
        }
    ]
    interfaceController.setRootTemplate(homeTemplate, animated: false, completion: nil)
    rebuildHome()
}

/// Push the library picker on top of Home. Selecting a library pops back (see CarPlayLibraryController).
func presentLibraryPicker() {
    guard let library = libraryController else { return }
    // Guard against double-taps re-pushing the same template.
    guard interfaceController.topTemplate !== library.template else { return }
    library.reload()
    interfaceController.pushTemplate(library.template, animated: true) { ok, error in
        if !ok { AbsLogger.error(message: "CarPlay: pushTemplate(library) failed: \(String(describing: error))") }
    }
}
```

- [ ] **Step 2: Simplify `refresh()`** (no Library tab to reload; the picker reloads itself when opened). Replace the body:

```swift
func refresh() {
    rebuildHome()
}
```

- [ ] **Step 3: Pop back after selecting a library.** In `CarPlayLibraryController.swift`, the row handler already sets `activeLibraryId`, calls `rebuildHome()`, and re-`reload()`s for the checkmark. Add the pop so the driver returns to Home. Replace the handler block inside `reload()`:

```swift
row.handler = { [weak self] _, completion in
    completion()
    self?.manager?.activeLibraryId = library.id
    self?.manager?.rebuildHome()
    self?.reload()
    self?.manager?.interfaceController.popTemplate(animated: true, completion: nil)
}
```

- [ ] **Step 4: Build & run on the simulator.**

Run: `mcp__xcode__build_run_sim`
Expected: build SUCCEEDED, app launches.

- [ ] **Step 5: Verify behavior on the CarPlay simulator.** Bring up CarPlay (Simulator → I/O → External Displays → CarPlay). Confirm:
  - Home is the root screen with **no tab bar**, and a `books.vertical` icon appears in the top-right.
  - Tapping the icon pushes the **library list** with a **checkmark** on the active library.
  - Tapping a library returns to Home, Home's Recently Added updates, and reopening the picker shows the checkmark moved.

- [ ] **Step 6: Commit** (existing files only — no pbxproj change).

```bash
git add ios/App/App/carplay/CarPlayManager.swift ios/App/App/carplay/CarPlayLibraryController.swift
git commit -m "$(printf 'feat(carplay): move library switch to a Home picker button, drop tab bar\n\nThe Library tab only switched which library feeds Home, so replace it with a\nbooks.vertical button in Home'\''s top bar that pushes the library picker (with\nthe active-library checkmark) and pops back on select. Home becomes the CarPlay\nroot template; the CPTabBarTemplate and its delegate are removed.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01VGXdLsdadowp3z4FHQud6p')"
```

---

### Task 2: Cover carousel builder (version-laddered) + cover application

Add one reusable helper that builds a `CPListImageRowItem` cover carousel from a shelf title + items + covers, handling the iOS availability ladder and per-cover titles in one place, plus a helper that swaps in covers after they load.

**Files:**
- Create: `ios/App/App/carplay/CarPlayCarousel.swift`
- Test: none (CarPlay template objects can't be unit-tested; verified via Task 3 on the simulator)

**Interfaces:**
- Consumes: `BrowseItem` (`.title: String`, `.coverURL: URL?`), `CPMaximumNumberOfGridImages`.
- Produces:
  - `enum CarPlayCarousel { static func make(title: String, items: [BrowseItem], covers: [UIImage?], onSelect: @escaping (Int) -> Void) -> CPListImageRowItem }` — one carousel row; `covers[i]` is the sized cover for `items[i]` or `nil` (placeholder); `onSelect(index)` fires on tap.
  - `static func applyCovers(_ covers: [UIImage?], to row: CPListImageRowItem, titles: [String])` — reloads the row's images once covers are available.

- [ ] **Step 1: Create the carousel helper.** Create `ios/App/App/carplay/CarPlayCarousel.swift`:

```swift
//
//  CarPlayCarousel.swift
//  App
//
//  Builds a Home shelf as a single horizontal cover carousel (CPListImageRowItem) with a per-cover
//  title. Per-cover titles are only available on newer iOS, so the version ladder lives here in one
//  place: iOS 26 uses `elements`, iOS 17.4-25 uses `imageTitles`, older iOS shows covers without
//  captions. Missing covers use a placeholder so the row can render before covers finish loading.
//

import CarPlay
import UIKit

// @MainActor: every method constructs/mutates main-thread-only CarPlay template objects.
@MainActor
enum CarPlayCarousel {
    /// A neutral placeholder shown until a real cover loads (or when a cover fails to load).
    static let placeholder: UIImage = UIImage(systemName: "book.closed") ?? UIImage()

    static func make(title: String, items: [BrowseItem], covers: [UIImage?],
                     onSelect: @escaping (Int) -> Void) -> CPListImageRowItem {
        let capped = Array(items.prefix(Int(CPMaximumNumberOfGridImages)))
        let titles = capped.map { $0.title }
        let images = (0..<capped.count).map { covers.indices.contains($0) ? (covers[$0] ?? placeholder) : placeholder }

        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            let elements = zip(images, titles).map { CPListImageRowItemRowElement(image: $0, title: $1, subtitle: nil) }
            row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
        } else if #available(iOS 17.4, *) {
            row = CPListImageRowItem(text: title, images: images, imageTitles: titles)
        } else {
            row = CPListImageRowItem(text: title, images: images)
        }
        row.listImageRowHandler = { _, index, completion in
            completion()
            onSelect(index)
        }
        return row
    }

    /// Reload a carousel's images in place once covers have loaded, keeping the per-cover titles.
    static func applyCovers(_ covers: [UIImage?], to row: CPListImageRowItem, titles: [String]) {
        let images = (0..<titles.count).map { covers.indices.contains($0) ? (covers[$0] ?? placeholder) : placeholder }
        if #available(iOS 26.0, *) {
            row.elements = zip(images, titles).map { CPListImageRowItemRowElement(image: $0, title: $1, subtitle: nil) }
        } else {
            row.updateImages(images)
        }
    }
}
```

- [ ] **Step 2: Register the new file into the `Audiobookshelf` target.**

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
ruby - <<'RUBY'
require 'xcodeproj'
proj = Xcodeproj::Project.open('ios/App/App.xcodeproj')
target = proj.targets.find { |t| t.name == 'Audiobookshelf' }
rel = 'App/carplay/CarPlayCarousel.swift'
unless target.source_build_phase.files_references.any? { |r| r.respond_to?(:path) && r.path == rel }
  ref = proj.main_group.new_reference(rel)
  ref.name = 'CarPlayCarousel.swift'
  ref.source_tree = '<group>'
  target.add_file_references([ref])
  proj.save
  puts "added #{rel}"
end
RUBY
```

Note: confirm the `path` matches how sibling CarPlay files are referenced (they live under `ios/App/App/carplay/`; existing refs use paths relative to the App source root, e.g. `App/carplay/CarPlayManager.swift`). Adjust `rel` if the diff vs HEAD shows a different prefix.

- [ ] **Step 3: Build to verify it compiles.**

Run: `mcp__xcode__build_run_sim`
Expected: build SUCCEEDED (the helper is not called yet; this only checks the version-laddered API compiles against the SDK).

- [ ] **Step 4: Commit** with the commit-xcodeproj-changes skill (new file → pbxproj changed).

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
cat > /tmp/msg-carousel.txt <<'MSG'
feat(carplay): add version-laddered cover-carousel builder

CarPlayCarousel.make/applyCovers build a Home shelf as a CPListImageRowItem
horizontal cover carousel with a per-cover title, handling the iOS ladder in
one place: elements on iOS 26, imageTitles on 17.4-25, plain covers below.
Not wired in yet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VGXdLsdadowp3z4FHQud6p
MSG
.claude/skills/commit-xcodeproj-changes/scripts/commit-pbxproj.sh /tmp/msg-carousel.txt \
  ios/App/App/carplay/CarPlayCarousel.swift
```

Verify after: `git show HEAD:ios/App/App.xcodeproj/project.pbxproj | grep -cE 'NG5DZJG8LP|audiobookshelfngo'` → `0`.

---

### Task 3: Render Home as three carousels

Rewire `rebuildHome()` to build three `CPListImageRowItem` carousels (Continue Listening, Recently Added · <Library>, Downloads) via `CarPlayCarousel`, load covers through the existing `NSCache`, and update each row once its covers resolve. Remove the per-book `makeRow` vertical path.

**Files:**
- Modify: `ios/App/App/carplay/CarPlayManager.swift` (`rebuildHome()`, cover loading; remove `makeRow`)

**Interfaces:**
- Consumes: `CarPlayCarousel.make(title:items:covers:onSelect:)`, `CarPlayCarousel.applyCovers(_:to:titles:)`, `BrowseApi.continueListening()/recentlyAdded(libraryId:)/downloads()`, `BrowsePlaybackStarter.play`, existing `Self.coverCache`, `sizedCover(_:)`, `BrowseApi.bookLibraries()` (for the library name in the header).
- Produces: Home rendered as ≤3 carousels; `loadCover` for single `CPListItem`s is no longer used by Home.

- [ ] **Step 1: Add a carousel cover fetch that sizes on the main actor.** In `CarPlayManager.swift`, add alongside the existing cover cache. Note: the cache key is suffixed `#carousel` so carousel-sized covers don't collide with the (differently sized) list-item covers cached by the existing `loadCover`; and `sizedCarouselCover` runs on the main actor because it reads `interfaceController.carTraitCollection` (main-thread-only).

```swift
/// Fetch (or reuse from cache) the carousel-sized cover for one item. Returns nil if there is no
/// cover URL or the request fails; callers substitute a placeholder.
private func carouselCover(for item: BrowseItem) async -> UIImage? {
    guard let url = item.coverURL else { return nil }
    let key = "\(url.absoluteString)#carousel" as NSString
    if let cached = Self.coverCache.object(forKey: key) { return cached }
    let image: UIImage? = await withCheckedContinuation { continuation in
        ApiClient.getData(from: url) { continuation.resume(returning: $0) }
    }
    guard let image else { return nil }
    let sized = await MainActor.run { self.sizedCarouselCover(image) }
    Self.coverCache.setObject(sized, forKey: key)
    return sized
}

/// Crop to a centered square and resize to the CarPlay image-row max at the car's display scale.
/// Mirrors sizedCover(_:) but targets CPListImageRowItemRowElement/CPListImageRowItem sizing.
@MainActor
private func sizedCarouselCover(_ image: UIImage) -> UIImage {
    let maxPoints: CGSize = {
        if #available(iOS 26.0, *) { return CPListImageRowItemRowElement.maximumImageSize }
        return CPListImageRowItem.maximumImageSize
    }()
    guard maxPoints.width > 0, maxPoints.height > 0, let cg = image.cgImage else { return image }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let side = min(w, h)
    let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    guard let cropped = cg.cropping(to: cropRect) else { return image }
    let square = UIImage(cgImage: cropped)
    let format = UIGraphicsImageRendererFormat()
    format.scale = interfaceController.carTraitCollection.displayScale
    let renderer = UIGraphicsImageRenderer(size: maxPoints, format: format)
    return renderer.image { _ in square.draw(in: CGRect(origin: .zero, size: maxPoints)) }
}
```

- [ ] **Step 2: Resolve the active library name for the Recently Added header.** Add:

```swift
/// The display name of the active library, for the "Recently Added · <name>" header. Empty if unknown.
private func activeLibraryName() async -> String {
    let id = await MainActor.run { self.activeLibraryId }
    guard let id else { return "" }
    return await BrowseApi.bookLibraries().first(where: { $0.id == id })?.name ?? ""
}
```

- [ ] **Step 3: Rewrite `rebuildHome()` to build carousels.** Replace the whole method:

```swift
func rebuildHome() {
    homeTask?.cancel()
    // Cancel cover-loading tasks from a superseded rebuild so they can't apply to stale rows.
    coverTasks.forEach { $0.cancel() }
    coverTasks.removeAll()
    homeTask = Task { [weak self] in
        guard let self = self else { return }
        var libraryId = await MainActor.run { self.activeLibraryId }
        if libraryId == nil {
            let first = await BrowseApi.firstBookLibraryId()
            await MainActor.run { if self.activeLibraryId == nil { self.activeLibraryId = first } }
            libraryId = first
        }

        let continueListening = await BrowseApi.continueListening()
        var recentlyAdded: [BrowseItem] = []
        if let libraryId { recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId) }
        let downloads = BrowseApi.downloads()
        let libraryName = await self.activeLibraryName()
        if Task.isCancelled { return }

        // One shelf per non-empty source, each capped to the carousel max.
        struct Shelf { let title: String; let items: [BrowseItem] }
        let shelves: [Shelf] = [
            Shelf(title: "Continue Listening", items: continueListening),
            Shelf(title: libraryName.isEmpty ? "Recently Added" : "Recently Added · \(libraryName)", items: recentlyAdded),
            Shelf(title: "Downloads", items: downloads),
        ].filter { !$0.items.isEmpty }
            .map { Shelf(title: $0.title, items: Array($0.items.prefix(Int(CPMaximumNumberOfGridImages)))) }

        // Build rows with placeholders first so Home appears immediately, then fill covers per shelf.
        await MainActor.run {
            if Task.isCancelled { return }
            guard !shelves.isEmpty else {
                self.homeTemplate.updateSections([CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)])])
                return
            }
            let rows: [CPListImageRowItem] = shelves.map { shelf in
                CarPlayCarousel.make(title: shelf.title, items: shelf.items, covers: []) { [weak self] index in
                    guard shelf.items.indices.contains(index) else { return }
                    let item = shelf.items[index]
                    Task { @MainActor in
                        BrowsePlaybackStarter.play(item) {
                            self?.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        }
                    }
                }
            }
            self.homeTemplate.updateSections([CPListSection(items: rows)])

            // Load covers off the main actor, then apply to each row once its shelf is ready.
            // Tracked in coverTasks so a superseding rebuildHome() cancels them (see method top).
            for (shelf, row) in zip(shelves, rows) {
                let task = Task { [weak self] in
                    guard let self else { return }
                    var covers: [UIImage?] = []
                    for item in shelf.items {
                        if Task.isCancelled { return }
                        covers.append(await self.carouselCover(for: item))
                    }
                    if Task.isCancelled { return }
                    await MainActor.run {
                        CarPlayCarousel.applyCovers(covers, to: row, titles: shelf.items.map { $0.title })
                    }
                }
                self.coverTasks.append(task)
            }
        }
    }
}
```

Also add the tracking property near `homeTask` at the top of `CarPlayManager`:

```swift
/// Cover-loading tasks for the current Home render, cancelled when a newer rebuild starts.
private var coverTasks: [Task<Void, Never>] = []
```

- [ ] **Step 4: Remove the now-unused `makeRow` and `loadCover`.** Delete `func makeRow(_:) -> CPListItem` and `private func loadCover(_:into:)` from `CarPlayManager.swift` (Home no longer builds single `CPListItem` book rows; `carouselCover(for:)` + `sizedCarouselCover(_:)` replace `loadCover`). `Self.coverCache` is still used (by `carouselCover`). The old `private func sizedCover(_ image: UIImage) -> UIImage` becomes unused once `loadCover` is gone — delete it too (its logic now lives in `sizedCarouselCover`).

  Shelf-label note (reconciles spec §3c): the shelf name is the `CPListImageRowItem` **row text** (rendered above its carousel), not a separate `CPListSection` header — all three carousels live in one headerless `CPListSection`. This avoids double labeling and works across the availability ladder (row `text` is provided at init on every branch).

- [ ] **Step 5: Build & run.**

Run: `mcp__xcode__build_run_sim`
Expected: build SUCCEEDED.

- [ ] **Step 6: Verify on the CarPlay simulator.** Confirm:
  - Home shows up to three **horizontal cover carousels**; vertical scrolling is short (≤3 rows).
  - Each cover has its **book title** beneath it (per-cover titles require iOS 17.4+; on iOS 14–17.3 covers render without captions, which is expected). The Recently Added shelf label reads "Recently Added · <Library>".
  - Covers populate shortly after the row appears (placeholder → cover), and persist across navigation.
  - Tapping a cover starts playback and shows Now Playing.
  - Switching library via the picker rebuilds the shelves and the header name.
  - With nothing to play, Home shows the "Nothing to play" placeholder.

- [ ] **Step 7: Commit.**

```bash
git add ios/App/App/carplay/CarPlayManager.swift
git commit -m "$(printf 'feat(carplay): render Home shelves as horizontal cover carousels\n\nEach Home shelf (Continue Listening, Recently Added, Downloads) is now a single\nCPListImageRowItem cover carousel with a per-cover title, via CarPlayCarousel,\nshrinking Home from a long vertical list to <=3 rows. Recently Added header\nshows the active library name. Covers load through the existing NSCache and are\napplied per shelf once ready. Removes the per-book makeRow/loadCover path.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01VGXdLsdadowp3z4FHQud6p')"
```

---

### Task 4: Remove the now-dead section-budget capping

With three fixed carousels each capped independently, the cross-section fair-budget `BrowseSection.capped` is unused. Remove it and its tests to avoid dead code.

**Files:**
- Modify/Delete: `ios/App/Shared/util/browse/BrowseSection.swift`
- Delete: `ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseSectionTests.swift`
- Modify: `ios/App/App.xcodeproj/project.pbxproj` (drop the test file reference)

**Interfaces:**
- Consumes: nothing new.
- Produces: `BrowseSection` either deleted (if `capped` was its only member) or reduced to whatever `rebuildHome` still uses (it no longer uses `BrowseSection` after Task 3).

- [ ] **Step 1: Confirm `BrowseSection` is unused after Task 3.**

Run: `grep -rn "BrowseSection" ios/App --include='*.swift' | grep -v Tests`
Expected: no references outside its own definition (Task 3 stopped using it). If any remain, keep the type and remove only `capped`; otherwise delete the file.

- [ ] **Step 2: Delete both tracked source files** (assuming Step 1 shows `BrowseSection` fully unused).

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
git rm ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseSectionTests.swift \
       ios/App/Shared/util/browse/BrowseSection.swift
```

- [ ] **Step 3: Remove both file references AND their build-phase entries via the xcodeproj gem.** Removing the file ref alone can leave a stale `PBXBuildFile` in a target's Sources phase, breaking the build — so drop the build-phase entry from every target first.

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
ruby - <<'RUBY'
require 'xcodeproj'
proj = Xcodeproj::Project.open('ios/App/App.xcodeproj')
names = %w[BrowseSection.swift BrowseSectionTests.swift]
proj.targets.each do |t|
  t.source_build_phase.files.dup.each do |bf|
    t.source_build_phase.remove_build_file(bf) if bf.file_ref && names.include?(bf.file_ref.display_name)
  end
end
names.each { |n| proj.files.select { |f| f.display_name == n }.each(&:remove_from_project) }
proj.save
puts 'removed BrowseSection refs + build files'
RUBY
grep -c "BrowseSection" ios/App/App.xcodeproj/project.pbxproj  # expect 0
```

- [ ] **Step 4: Run the full unit-test suite.**

Run: `mcp__xcode__test_sim`
Expected: all remaining tests PASS (BrowseCache, BrowseItem, BrowseLibrary, NowPlayingInfo, Playback*, PlayerTimeUtils, SingleFlight), no `BrowseSection*` tests discovered, build SUCCEEDED.

- [ ] **Step 5: Commit** with the commit-xcodeproj-changes skill (pbxproj changed by the removal).

```bash
cd /Users/michaelngo/projects/audiobookshelf-app
cat > /tmp/msg-rmsection.txt <<'MSG'
refactor(carplay): drop unused BrowseSection budget capping

Home now renders fixed per-shelf carousels, each capped independently to
CPMaximumNumberOfGridImages, so the cross-section fair-budget BrowseSection.capped
and its tests are dead. Remove them.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VGXdLsdadowp3z4FHQud6p
MSG
.claude/skills/commit-xcodeproj-changes/scripts/commit-pbxproj.sh /tmp/msg-rmsection.txt
```

---

## Self-Review

**Spec coverage:**
- Nav: Home root + tab bar removed + library button + picker pop → Task 1. ✅
- Home carousels + per-cover title-only → Tasks 2–3. ✅
- Library name in Recently Added header (icon button choice) → Task 3 Step 3. ✅
- iOS availability ladder → Task 2 Step 1. ✅
- Cover loading via existing NSCache → Task 3 Steps 1,3. ✅
- Capping model change / BrowseSection removal → Task 4. ✅
- All-empty "Nothing to play" fallback → Task 3 Step 3. ✅
- Checkmark carried into picker → Task 1 (uses existing uncommitted change). ✅

**Placeholder scan:** none — every code step contains full code; the one "confirm the pbxproj path prefix" note in Task 2 Step 2 is a verification instruction with the concrete expected value given, not a deferred requirement.

**Type consistency:** `CarPlayCarousel.make(title:items:covers:onSelect:)` and `applyCovers(_:to:titles:)` are defined in Task 2 and consumed with the same signatures in Task 3. `sizedCover(for:) async -> UIImage?` (new) is distinct from `sizedCover(_ image:) -> UIImage` (existing) and both are used in Task 3. `presentLibraryPicker()` defined and used in Task 1.

**Codex review incorporated (2026-07-14):** carousel covers size to `CPListImageRowItemRowElement`/`CPListImageRowItem.maximumImageSize` (not `CPListItem`) via a main-actor `sizedCarouselCover`; `CarPlayCarousel` is `@MainActor`; `carouselCover` sizes on the main actor (no off-main `carTraitCollection`); `presentLibraryPicker` guards `topTemplate` and logs push failures; cover-load tasks are tracked in `coverTasks` and cancelled on rebuild; shelf label is the row `text` (one headerless section) — spec §3c reconciled; app-target floor clarified to iOS 14; verification made OS-specific for titles; Task 4 removes build-phase entries before file refs.

**Open risks (resolve during implementation, not blockers):**
- `CPMaximumNumberOfGridImages` is an `NSUInteger`; `Int(...)` cast used for `prefix`. Confirm it imports as a Swift constant (it does via the CarPlay module).
- `row.updateImages(_:)` is deprecated at iOS 26 but only reached on `< iOS 26` branches, so no deprecation warning fires on the 26 path. Acceptable.
- Verify `listImageRowHandler` fires for the iOS 26 `elements`-based row on the simulator (Task 3 Step 6); if not, fall back to per-element selection.
