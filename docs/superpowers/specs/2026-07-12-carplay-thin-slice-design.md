# CarPlay (#475) — thin vertical slice design

Date: 2026-07-12
Branch: `feat/sdk-browse-endpoints` (home for all Swift-SDK-dependent native features)
Status: approved (design), implementation in progress

## Goal

First native CarPlay experience for the audiobookshelf iOS app: browse a small set of
book lists in the car, tap to play, and control playback from the system Now Playing
screen. Proves the whole native pipeline (SDK browse endpoint → CarPlay list → native
playback → system transport) end-to-end. Books only in this slice; podcasts, series,
authors, collections, and voice search come in later passes.

## Non-goals (this slice)

- Podcasts / episodes.
- Series / authors / collections browse; voice (Siri) search.
- Library switching UI (uses the user's default/first library for the server shelf).
- Any change to the existing phone player UI or playback engine.

## Architecture

CarPlay runs as a separate `UIScene` (`CPTemplateApplicationScene`), fully native — no
WebView. Only the browse UI + scene wiring are new; playback and Now Playing are reused.

```
CarPlaySceneDelegate : CPTemplateApplicationSceneDelegate
  templateApplicationScene(_:didConnect:)    → hold CPInterfaceController; set root template
  templateApplicationScene(_:didDisconnect:) → tear down

CarPlayManager
  buildRootTemplate() → CPListTemplate with up to 3 sections:
    • "Continue Listening" → ABSApi.getItemsInProgress()          (server, user-wide)
    • "Recently Added"     → ABSApi.getLibraryPersonalizedView()  (server, default library, "recently-added" shelf)
    • "Downloads"          → Database.shared.getLocalLibraryItems(mediaType: .book)  (local, always works)
  each source loads async; on server error/offline the two server sections are omitted,
    leaving Downloads (a car is frequently offline — must stay usable).
  row select → CarPlayPlaybackStarter:
    • local item  → build local PlaybackSession (mirrors AbsAudioPlayer local path)
    • server item → ApiClient.startPlaybackSession(libraryItemId:episodeId:forceTranscode:false)
    → PlayerHandler.startPlayback(sessionId:) → CarPlay auto-shows CPNowPlayingTemplate
```

## Components (new, under `ios/App/App/carplay/`)

- `CarPlaySceneDelegate.swift` — scene lifecycle; owns the `CPInterfaceController`.
- `CarPlayManager.swift` — builds sections, async-loads each source, maps items →
  `CPListItem` (title, detail=author, cover art via the by-id cover URL), handles selection.
- `CarPlayListItem.swift` — a small pure view-model + mapper (server `libraryItemMinified` /
  local `LocalLibraryItem` → `{ id, title, author, coverURL, isLocal }`). **This is the
  unit-tested piece.**
- `Info.plist` — add `UIApplicationSceneManifest` (`UIApplicationSupportsMultipleScenes = true`)
  declaring ONLY the CarPlay role (`CPTemplateApplicationSceneSessionRoleApplication`) →
  `CarPlaySceneDelegate`. No window-scene role, so the phone app keeps its existing
  AppDelegate `window` lifecycle untouched. **Verify the phone window still launches.**
- `App.entitlements` — `com.apple.developer.carplay-audio = true`.

## Reused unchanged

`ABSApi` (browse), `ApiClient.startPlaybackSession`, `PlayerHandler.startPlayback`,
`Database.shared.getLocalLibraryItems`, and the existing `MPRemoteCommandCenter` handlers +
`MPNowPlayingInfoCenter` in `AudioPlayer.swift` (so the system Now Playing screen —
play/pause/skip, cover, chapters — works automatically once playback starts).

## Data flow (server tap)

`CPListItem.select` → `ApiClient.startPlaybackSession(libraryItemId:)` (async, off-thread;
Realm session built + used on main, per the migration's main-thread contract) → session
saved → `PlayerHandler.startPlayback(sessionId:)` → AVPlayer + `NowPlayingInfo` populate
`MPNowPlayingInfoCenter` → CarPlay presents `CPNowPlayingTemplate`.

## Error / offline handling

Each server source load is independent and failure-tolerant: on error the section is
skipped (logged via AbsLogger), never crashing the root template. Downloads always renders.
If all three are empty, show a single disabled "Nothing to play" row.

## Testing

- Unit: `CarPlayListItem` mapper (server DTO → view model; local item → view model;
  cover-URL derivation; nil/optional defaults) in `AudiobookshelfUnitTests`.
- Manual: CarPlay Simulator (Xcode Simulator → I/O → External Displays → CarPlay).
  **Blocked** until the CarPlay-audio entitlement is granted (see below).

## Hard external gate — CarPlay-audio entitlement

`com.apple.developer.carplay-audio` must be **requested from and granted by Apple**
(developer.apple.com CarPlay request form); it is not in the standard profile. Until it is
granted and added to the provisioning profile, the CarPlay scene will not instantiate —
even in the Simulator. Decision (user, 2026-07-12): **build the code now** (compiles +
unit-tested mapping), user requests the entitlement in parallel; wire the entitlement file,
provisioning, and live testing once granted.

## Build sequence

1. `CarPlayListItem` view-model + mapper (TDD).
2. `CarPlayManager` (sections, async load, selection → playback).
3. `CarPlaySceneDelegate`.
4. Info.plist scene manifest + `App.entitlements` (entitlement stays inert until Apple grants).
5. Compile the app; run unit tests. (Live CarPlay test deferred to entitlement grant.)
