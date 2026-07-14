# CarPlay (#475) — activation + polish design

Date: 2026-07-13
Branch: `feat/sdk-browse-endpoints` (home for all Swift-SDK-dependent native features)
Status: approved (design)
Supersedes the activation step (§ "Info.plist scene manifest") of
`2026-07-12-carplay-thin-slice-design.md`, which is now known-broken (see § 1).

## Goal

Apple has **granted** the `com.apple.developer.carplay-audio` entitlement. Activate the
already-built CarPlay thin slice for real (it currently compiles but is never instantiated,
because the scene + entitlement are deliberately unwired), and land three polish items on top:
**library switching**, **on-screen search (+ verify the existing Siri voice path)**, and
**better covers / Now Playing artwork**. Books only, as before.

## What already exists (do not rebuild)

- `ios/App/Shared/util/browse/BrowseApi.swift` — `continueListening()`, `recentlyAdded(libraryId:)`,
  `downloads()`, `firstBookLibraryId()`, **`search(query:)`** (written, not yet wired into CarPlay).
- `ios/App/Shared/util/browse/BrowseItem.swift` — pure Equatable view model + lenient decoders
  (server minified item, items-in-progress, personalized "recently-added" shelf, search matches,
  local item). Cover URL forces `format=jpeg` (WebP decodes unreliably). Unit-tested.
- `ios/App/Shared/util/browse/BrowsePlaybackStarter.swift` — starts native playback reusing the
  phone paths (prefers a downloaded copy even for server rows); posts `sessionStarted` to sync the
  WebView player.
- `ios/App/App/carplay/CarPlayManager.swift` — single-`CPListTemplate` root with the three sections;
  offline-tolerant (server sections omitted on failure, Downloads always renders).
- `ios/App/App/carplay/CarPlaySceneDelegate.swift` — `CPTemplateApplicationSceneDelegate`; owns the
  `CPInterfaceController`.
- `ios/App/App/shortcuts/AudiobookIntents.swift` — **App Intents** Siri surface (#725):
  `PlayAudiobookIntent` (an `AudioPlaybackIntent`) resolves a spoken title via
  `BrowseApi.search()`; `ContinueListeningIntent` resumes the latest. Phrase:
  *"Play &lt;audiobook&gt; in Audiobookshelf"*. This is the hands-free voice-play path and it
  already exists — CarPlay work does NOT need a SiriKit Media Intents extension.
- `ios/App/App/App.entitlements` — currently only app-groups; the `carplay-audio` key was dropped
  during the widget App Group work and must be re-added.

## Research grounding (Apple CarPlay UX)

- **Root layout for a browse audio app:** `CPTabBarTemplate` containing `CPListTemplate`s is the
  standard pattern; tab bar holds up to ~5 tabs.
- **List limits (driving safety):** `CPListTemplate.maximumItemCount` can be as low as **12** while
  driving (up to ~24); `maximumSectionCount` ~50. Query these at runtime and **subset** — do not
  assume a fixed count. Navigation depth is capped (~5); this design stays shallow (tab → list →
  Now Playing).
- **List cover art:** size to `CPListItem.maximumImageSize` (resolution-independent points) and
  respect `interfaceController.carTraitCollection.displayScale` (2×/3×); crop square.
- **Now Playing:** `CPNowPlayingTemplate` is automatic from `MPNowPlayingInfoCenter` +
  `MPRemoteCommandCenter`; artwork comes from `MPMediaItemArtwork` in the now-playing info.
- **Search:** `CPSearchTemplate` gives an in-app search surface (car keyboard + dictation button;
  partly restricted while driving). Distinct from the Siri App Intents path, which is the true
  hands-free route and already works.

## Non-goals (this pass)

Podcasts/episodes; series/authors/collections drill-down; a separate SiriKit Media Intents
extension; changes to the phone player UI or playback engine.

## 1. Scene wiring — decided: Approach A (dual-role manifest)

**Problem:** a CarPlay-*only* `UIApplicationSceneManifest` with
`UIApplicationSupportsMultipleScenes = true` **black-screens the phone app** (A/B confirmed on sim,
2026-07-12): once multi-scene support exists, iOS stops building the main window from
`UIMainStoryboardFile`/AppDelegate and there is no window-scene config to replace it.

**Approach A (chosen):** the manifest declares **both** scene roles:

- `UIWindowSceneSessionRoleApplication` → a config with `UISceneStoryboardFile = Main` (and no
  custom delegate), so iOS rebuilds the phone window from `Main.storyboard` via a window scene.
- `CPTemplateApplicationSceneSessionRoleApplication` → `CarPlaySceneDelegate` for CarPlay.

**Hard gate (do first, verifiable on sim WITHOUT the entitlement):** the phone app must still launch
to its full home screen. Capacitor builds `AppDelegate.window` itself; a storyboard-backed window
scene may double-up. **A/B test phone launch on the simulator before wiring anything else.** Beyond
launch, also smoke-test deep links, widget cold-launch resume, and orientation, since those touch
the window/launch path.

**Fallback (Approach B), if A double-windows:** implement
`application(_:configurationForConnecting:options:)` in `AppDelegate` — return the CarPlay
`UISceneConfiguration` (delegate `CarPlaySceneDelegate`) for `role == .carTemplateApplication`, and
a default storyboard-backed config otherwise. Documented here so implementation can switch without
re-deciding. Approach C (full Capacitor `UIWindowSceneDelegate` migration) is rejected as too
invasive (touches launch, deep links, widget cold-launch resume).

## 2. Root layout → `CPTabBarTemplate` (enables library switching)

Replace the single-list root in `CarPlayManager` with a `CPTabBarTemplate`:

- **Tab "Home"** — the existing Continue Listening / Recently Added / Downloads list. Default tab;
  the Downloads section keeps it useful offline. `recentlyAdded` uses the currently-selected library
  (default = first book library) rather than a hardcoded lookup.
- **Tab "Library"** — a `CPListTemplate` listing the server's **book** libraries (new
  `BrowseApi.bookLibraries()` returning `{id, name}`; generalizes the existing `firstBookLibraryId()`
  decode). Selecting one sets the active library and refreshes Home's Recently Added. On offline/error
  the tab shows a single disabled "Libraries unavailable" row; Home still works from Downloads.
- **Tab "Search"** — see § 3.

**Runtime limits:** each `CPListTemplate` queries `maximumItemCount` and subsets its items;
sections respect `maximumSectionCount`. Add a small helper (e.g. `CPListTemplate.capped(sections:)`)
so every template goes through one capping path.

Guard the tab-bar delegate against the known first-selection / reselection double-callback.

## 3. Search — verify Siri + add `CPSearchTemplate`

- **Verify (no new code):** confirm *"Play &lt;book&gt; in Audiobookshelf"* fires from CarPlay's
  Siri and reaches `BrowsePlaybackStarter`. Record the result in the plan; if it does not fire while
  docked, capture the failure for a follow-up (not fixed this pass unless trivial).
- **Add `CPSearchTemplate`** as the Search tab, wired to `BrowseApi.search(query:)`:
  - `searchTemplate(_:updatedSearchText:completionHandler:)` → debounced `BrowseApi.search` →
    `[CPListItem]` via the existing `BrowseItem → CPListItem` mapper (extracted from `CarPlayManager`
    so search and browse share it).
  - `searchTemplate(_:selectedResult:completionHandler:)` → `BrowsePlaybackStarter.play` → push
    `CPNowPlayingTemplate`.
  - Results also honor `maximumItemCount`.

## 4. Covers + Now Playing artwork

- **List covers:** in the cover loader, resize the decoded image to `CPListItem.maximumImageSize`
  (using `carTraitCollection.displayScale`), cropped square, before `setImage`. Keep the `format=jpeg`
  cover URL. Loads stay best-effort/async; a failed cover just leaves the row imageless.
- **Now Playing artwork:** populate `MPMediaItemArtwork` in `MPNowPlayingInfoCenter` from the decoded
  jpeg cover so the CarPlay Now Playing screen (and the phone lock screen) shows the book cover —
  closing the known native WebP-artwork gap. Locate where now-playing info is set (`AudioPlayer.swift`
  / `NowPlayingInfo`) and set artwork there; decode via the same jpeg URL trick. Scope this to setting
  artwork correctly; no other now-playing changes.

## 5. Activation — entitlement + provisioning

- Re-add `com.apple.developer.carplay-audio = true` to `ios/App/App/App.entitlements` (keep
  app-groups).
- Wire `CODE_SIGN_ENTITLEMENTS` to `App.entitlements` for the App target; commit the `project.pbxproj`
  change via the **commit-xcodeproj-changes** skill (the file is `assume-unchanged` with a local
  signing override — a plain `git add` no-ops or leaks the local team).
- Confirm the granted entitlement is present in the provisioning profile used for device/TestFlight
  builds (the fork's fastlane automation). Sim CarPlay testing does not need the profile, but device
  builds will fail to sign until the profile carries the entitlement.

## Components (delta from the thin slice)

New / changed under `ios/App/App/carplay/` and `ios/App/Shared/util/browse/`:

- `CarPlayManager.swift` — build a `CPTabBarTemplate` root; extract the `BrowseItem → CPListItem`
  mapper (shared with search); add active-library state; route through the capping helper.
- `CarPlaySearchController` (new) — `CPSearchTemplateDelegate` over `BrowseApi.search`.
- `CarPlayLibraryController` (new, or a method on the manager) — the Library tab list.
- `BrowseApi.swift` — add `bookLibraries()`; `recentlyAdded` already takes a `libraryId`.
- `Info.plist` — dual-role `UIApplicationSceneManifest` (Approach A).
- `App.entitlements` — re-add carplay-audio.
- Now-playing artwork population in the existing audio player path.

## Testing / verification ladder

1. **Phone window still launches** on the simulator with the dual-role manifest — the gate; do this
   first. Also smoke-test deep links / widget cold-launch resume / orientation.
2. **Unit tests** (`AudiobookshelfUnitTests`): extend `BrowseItemTests` for `search` and
   `bookLibraries` mapping; test the item-capping helper (subset at `maximumItemCount`).
3. **CarPlay Simulator** (Xcode → I/O → External Displays → CarPlay), now unblocked by the granted
   entitlement: browse all tabs, switch library, search, tap → Now Playing with cover art; verify
   offline behavior (Downloads-only) by killing the network.
4. **Siri from CarPlay**: *"Play &lt;book&gt; in Audiobookshelf"* resolves and plays.

## Build sequence

1. Scene manifest (Approach A) + phone-launch A/B gate on sim. If broken → switch to Approach B.
2. `App.entitlements` carplay-audio + `CODE_SIGN_ENTITLEMENTS` (commit-xcodeproj-changes skill).
3. Extract the `CPListItem` mapper + add the `maximumItemCount` capping helper (TDD).
4. `CPTabBarTemplate` root with Home tab (existing sections through the new mapper/capping).
5. Library tab + `BrowseApi.bookLibraries()` + active-library state (TDD for the mapper).
6. Search tab (`CPSearchTemplate` + `BrowseApi.search`).
7. List cover sizing to `maximumImageSize`; Now Playing `MPMediaItemArtwork`.
8. Live CarPlay Simulator pass + Siri verification.
