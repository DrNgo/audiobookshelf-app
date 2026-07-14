# CarPlay Home carousels + Home library picker — design

Date: 2026-07-14
Branch: `feat/sdk-browse-endpoints` (future advplyr-upstream PR branch — keep commits upstream-mergeable)
Status: approved direction, pending spec review

## 1. Goal & intent

Two related CarPlay browse improvements the user asked for:

1. **Fold library selection into Home.** Today a separate "Library" tab exists only to switch which
   library feeds Home's Recently Added shelf. Replace it with a **library-picker button in Home's top
   bar** (CarPlay's native equivalent of a dropdown) and **remove the tab bar** (a one-tab tab bar is
   pointless once Library is gone). The Home root becomes the single browse screen.

2. **Shorten Home's long vertical scroll.** Today Home is a long vertical list (one `CPListItem` per
   book across three sections). Replace each shelf with a **single horizontal cover carousel**
   (`CPListImageRowItem`) with a **per-cover title** so similar/series books are distinguishable.
   Vertical height drops from ~30+ rows to 3.

Books only (unchanged). Playback path unchanged (tap → `BrowsePlaybackStarter.play`).

## 2. Current state (what exists today)

- `CarPlaySceneDelegate` → `CarPlayManager.start()` builds `CPTabBarTemplate([Home, Library])` as root.
- `CarPlayManager.rebuildHome()` builds Home as a `CPListTemplate` with sections Continue Listening /
  Recently Added / Downloads, one `CPListItem` per book (`makeRow`), covers loaded per row via
  `loadCover` (now `NSCache`-backed).
- `CarPlayLibraryController` is the **Library tab**: a `CPListTemplate` listing book libraries; tapping
  a row sets `manager.activeLibraryId` + `rebuildHome()`. An active-library **checkmark** accessory was
  just added (currently uncommitted) — it carries into the picker below.
- `BrowseApi` reads route through `BrowseCache` (TTL + last-good). `BrowseSection.capped()` distributes
  a total item budget fairly across the three vertical sections.
- Deployment target: **iOS 13/14**.

## 3. Design

### 3a. Navigation: Home as root + library-picker button

- `CarPlayManager.start()` sets the **Home `CPListTemplate` as the root** (`setRootTemplate`), no tab bar.
  Remove `CPTabBarTemplate`, the `CPTabBarTemplateDelegate` conformance, and the tab wiring.
- Home gets a **trailing navigation-bar button** (`CPBarButton`, image type, `books.vertical` SF Symbol).
  Tapping it **pushes the library picker** template.
- Scene reactivation recovery (`refresh()`) still calls `rebuildHome()`; it no longer reloads a Library
  tab (there is none) — the picker reloads itself when next opened.

### 3b. Library picker (was the Library tab)

- `CarPlayLibraryController` becomes the **pushed picker**, not a tab. Same content: a `CPListTemplate`
  listing book libraries, each row carrying the **active-library checkmark** (`accessoryImage`,
  supplied at construction; active id = `manager.activeLibraryId ?? libraries.first?.id`).
- Selecting a row: set `manager.activeLibraryId`, `rebuildHome()`, refresh the picker's checkmark, and
  **pop back to Home** (`interfaceController.popTemplate`). `bookLibraries()` is cached, so re-render
  makes no extra request.
- Empty/offline: single disabled "Libraries unavailable" row (unchanged).

### 3c. Home shelves as horizontal cover carousels

- `rebuildHome()` builds **one `CPListImageRowItem` per non-empty shelf** (Continue Listening,
  Recently Added, Downloads), each in its own `CPListSection` whose **header** is the shelf name — and
  for Recently Added, **"Recently Added · <Library>"** so the current library is visible (per the
  chosen design: icon button + library name in the header).
- Each carousel shows the first N covers, N = the `CPListImageRowItem` per-row maximum (confirm exact
  cap at implementation; ~8–12). Tapping a cover at `index` → `BrowsePlaybackStarter.play(items[index])`
  then push `CPNowPlayingTemplate.shared` (same as today's row handler).
- **Per-cover title = book title only** (author repeats within a series; title differentiates better).
- If **all** shelves are empty → a single "Nothing to play" `CPListItem` placeholder (unchanged intent).

### 3d. Per-cover titles + iOS availability ladder (KEY constraint)

Per-cover titles are not available on all supported OS versions. Ladder, newest first:

- **iOS 26+**: build the row from `CPListImageRowItem.elements` (`[CPListImageRowItemRowElement]`), each
  element = cover + title. This is the non-deprecated modern API.
- **iOS 17.4–25.x**: use `CPListImageRowItem(text:images:imageTitles:)` (per-cover titles; `imageTitles`
  is deprecated in 26 but present here).
- **iOS < 17.4**: `CPListImageRowItem(text:images:)` — covers **without** per-cover titles (graceful
  degradation; the shelf still works, just no caption). Acceptable: CarPlay users skew to recent iOS,
  and per-cover titles are an enhancement, not correctness.

Encapsulate this in one helper (e.g. `makeCarousel(title:items:) -> CPListImageRowItem`) with
`if #available` branches, so the version logic lives in exactly one place.

### 3e. Cover loading into carousels

- `CPListImageRowItem` takes its images up front; covers arrive async. Build the row with placeholder
  images (or the cached ones), then **`update(_:)`** the images as covers load. Reuse the existing
  cover `NSCache` (sized covers keyed by URL) so covers are fetched at most once. Loading covers for a
  carousel is the same set of URLs as before, so no new rate-limit pressure.

### 3f. Capping model change

- Per-shelf independent cap (`prefix(maxImagesPerRow)`) replaces the cross-section total-budget
  `BrowseSection.capped()`. With three fixed carousels there is no shared vertical budget to divide.
- Consequence: `BrowseSection.capped()` and `BrowseSectionTests` likely become unused — remove or
  repurpose them as part of this change rather than leaving dead code.

## 4. Components to modify

- `ios/App/App/carplay/CarPlayManager.swift` — root = Home (no tab bar); nav-bar library button; Home
  shelves as carousels; carousel builder + availability ladder; cover-into-carousel loading; remove tab
  delegate.
- `ios/App/App/carplay/CarPlayLibraryController.swift` — becomes the pushed picker (pop on select);
  keep the checkmark.
- `ios/App/Shared/util/browse/BrowseSection.swift` (+ its tests) — capping model change / removal.
- Possibly a small `BrowseItem`→element-title mapping helper (title only) if worth a unit test.

## 5. Data flow

Home rebuild: `BrowseApi.continueListening()` / `recentlyAdded(activeLibraryId)` / `downloads()` (via
`BrowseCache`, unchanged) → build ≤3 carousels → load covers (cached) → `update` rows. Library button →
push picker → `bookLibraries()` (cached) → select → set `activeLibraryId` + `rebuildHome()` + pop.

## 6. Error / empty handling

- Failed/rate-limited fetch → `BrowseCache` returns last-good (already handled); a shelf with no items
  is omitted; all-empty → "Nothing to play". Offline library picker → "Libraries unavailable".

## 7. Testing

- Unit-testable: capping/prefix logic if extracted; `BrowseItem`→title mapping. Existing `BrowseCache`,
  `BrowseItem`, `BrowseLibrary` tests stay green.
- CarPlay-UI-bound pieces (carousel construction, nav button, push/pop, availability branches) are
  verified on the CarPlay **simulator** behaviorally, and ideally on the device — noting the simulator's
  known rendering unreliability (Now Playing precedent).

## 8. Risks / open items (resolve in the plan)

- **Availability ladder** is the main complexity; confirm exact `elements` / `CPListImageRowItemRowElement`
  and `imageTitles` signatures against the iOS 26 SDK during implementation.
- Confirm the exact **per-row image maximum** and the **cover-tap handler API**
  (`listImageRowHandler` vs element handler) on iOS 26.
- Cover `update(_:)` timing on `CPListImageRowItem` (rebuild vs in-place update) — verify no flicker.

## 9. Out of scope (YAGNI)

- Library drill-down to browse a whole library's contents (this keeps the switch-active-library model,
  just relocated to Home). Series/author/collection drill-down, podcasts, collections — still deferred.
- Collapsible sections — not a CarPlay capability, and made unnecessary by the carousels.
