# Migrating off the hand-rolled `ApiClient` to the generated `ABSApiClient`

This is a handoff guide for incrementally replacing the hand-written native API layer
(`ios/App/Shared/util/ApiClient.swift` + the Realm-backed `models/server/*` types) with the
generated, typed `ABSApiClient` package.

**Read this first:** do not attempt a big-bang swap. The two clients have a real impedance
mismatch, and the existing one carries subtle production behavior (token refresh that the
WebView depends on, offline-sync reconciliation, lenient decoding). The safe path is a
strangler-fig migration: keep `ApiClient` working, move traffic endpoint-by-endpoint behind
a mapping layer, and delete `ApiClient` only once parity is proven.

## Where we are now (Phase 0 — additive, already done)

- `ABSApiClient` is generated + wired into the `Audiobookshelf` target and builds green.
- It is intended first for **new** native surfaces (CarPlay, widgets, Siri Shortcuts,
  background sync) — those have no existing client to conflict with.
- Nothing in the existing player/download/DB paths has changed. `ApiClient` still owns all
  current traffic.

## The core mismatch to bridge

| Concern | Hand-rolled `ApiClient` | Generated `ABSApiClient` |
|--------|--------------------------|---------------------------|
| Models | Realm objects (`class PlaybackSession: Object`, `MediaProgress: EmbeddedObject`, `User: EmbeddedObject`) — persisted, reference types, need write transactions / freeze-thaw | Plain `Codable` value DTOs (`Components.Schemas.*`) |
| Transport | Alamofire, static methods, callback + `async` | `Client` over `URLSessionTransport` |
| Auth | 401 → `/auth/refresh` with `x-refresh-token`, then update `SecureStorage` + `Store.serverConfig` + `Database` **and notify the WebView** via `AbsDatabase.tokenRefreshCallback("onTokenRefresh")` | `BearerAuthMiddleware` injects a **static** token only |
| Decoding | Lenient — `doubleOrStringDecoder` tolerates numbers-returned-as-strings | Strict — expects exact JSON types |

The generated DTOs are not drop-in for the Realm models the rest of the app persists and
observes. Every migrated endpoint needs a **mapping layer** (DTO ↔ Realm) so the persistence
and player code keep seeing the Realm types they expect.

## Endpoint inventory & target mapping

| `ApiClient` method | Endpoint | Generated equivalent | Migration notes |
|--------------------|----------|----------------------|-----------------|
| `getCurrentUser()` | `GET /api/me` | `client.getCurrentUser()` | DTO `userMinimal` → Realm `User`. Easiest first move (read-only). |
| `getMediaProgress(...)` | `GET /api/me/progress/{id}[/{ep}]` | `getMediaProgress` / `getPodcastEpisodeMediaProgress` | DTO `mediaProgress` → Realm `MediaProgress`. Watch string-vs-number decoding. |
| `updateMediaProgress(...)` | `PATCH /api/me/progress/{id}[/{ep}]` | `updateMediaProgress` / `updatePodcastEpisodeMediaProgress` | Body = `mediaProgressUpdate`. Write path — verify server state after. |
| `startPlaybackSession(...)` | `POST /api/items/{id}/play[/{ep}]` | `playLibraryItem` / `playPodcastEpisode` | DTO `playbackSession` → Realm `PlaybackSession` (richest mapping). Build `deviceInfoRequest` from the current `deviceInfo` dictionary. |
| `reportPlaybackProgress(report,sessionId)` | `POST /api/session/{id}/sync` | `syncPlaybackSession` | Body = `playbackReport` (`currentTime`,`duration`,`timeListened`). |
| `reportLocalPlaybackProgress(session)` | `POST /api/session/local` | `syncLocalPlaybackSession` | Realm `PlaybackSession` → DTO `playbackSession`. |
| `reportAllLocalPlaybackSessions(sessions)` | `POST /api/session/local-all` | `syncAllLocalPlaybackSessions` | Body = `localPlaybackSessionSyncAll` (`sessions[]` + `deviceInfo`). |
| `getLibraryItemWithProgress(...)` | `GET /api/items/{id}?expanded=1&include=progress` | **Not generated yet** | The expanded-item endpoint is **not in the OpenAPI spec** we generated from (only auth/session/progress were added). Add `/api/items/{id}` to the spec and regenerate before migrating this. |
| `getData(...)` cover, `AbsDownloader` file/cover, `AudioPlayer` stream URLs | `GET /api/items/{id}/cover`, `/api/items/{id}/file/{ino}[/download]` | **Leave as-is** | These are binary/streaming, not JSON operations. Keep the direct authenticated-URL construction; they are not migration targets. |
| token refresh (internal) | `POST /auth/refresh` | `client.refreshToken` | Must be reimplemented as a refresh-aware middleware — see below. The hardest piece. |
| `pingServer()` | `GET /ping` | not in spec | Trivial; leave or add to spec. |

## Phased plan

### Phase 1 — Foundation (do before migrating any traffic)
1. **Refresh-aware auth middleware.** Replace/extend `BearerAuthMiddleware` so that on a 401
   it performs the same flow `ApiClient.handleTokenRefresh` does today: call `refreshToken`
   with the stored `x-refresh-token`, persist the new tokens to `SecureStorage`,
   `Store.serverConfig`, and `Database`, **fire `AbsDatabase.tokenRefreshCallback` so the
   WebView stays authenticated**, then retry the original request. Missing the WebView
   notification will silently log the web layer out — this is the highest-risk detail.
2. **Client provider.** A small `ABSClientProvider` that builds a `Client` from the active
   `Store.serverConfig` (base URL + access token) and the middleware above. One place that
   owns configuration.
3. **Mapping layer.** `DTO ↔ Realm` converters with unit tests: `Components.Schemas.mediaProgress`
   ↔ `MediaProgress`, `userMinimal` ↔ `User`, `playbackSession` ↔ `PlaybackSession`. Mind
   Realm write transactions and freeze/thaw; do conversions off the persisted objects.

### Phase 2 — Read-only endpoints (lowest risk)
Migrate `getCurrentUser` then `getMediaProgress` behind the mapping layer. Verify the mapped
Realm objects match what `ApiClient` produced for the same account. Keep `ApiClient` as the
fallback until parity is confirmed.

### Phase 3 — Progress writes & session sync (playback-critical)
Migrate `updateMediaProgress`, then `syncPlaybackSession`, `syncLocalPlaybackSession`,
`syncAllLocalPlaybackSessions`. Re-verify the offline-reconciliation logic in
`syncLocalSessionsWithServer` (the `lastUpdate` comparison that decides local-vs-server
winner) still holds when the payloads come from the generated client.

### Phase 4 — Start playback session
Migrate `startPlaybackSession`. Requires the full `playbackSession` DTO → Realm mapping,
including `audioTracks`, `chapters`, and `deviceInfo`. Exercise real playback end-to-end.

### Phase 5 — Expanded item
Add `/api/items/{id}` (expanded, `include=progress`) to the OpenAPI spec, regenerate, then
migrate `getLibraryItemWithProgress`.

### Phase 6 — Retire `ApiClient`
Once all JSON endpoints run through `ABSApiClient`, delete the request plumbing in
`ApiClient.swift`. Keep only the binary URL builders (cover/file/stream) — fold them into a
tiny helper. Then check whether **Alamofire** is still referenced anywhere; if not, drop the
`pod 'Alamofire'` line. (`grep -rl Alamofire ios/App --include=*.swift`.)

## Risks & gotchas (test these explicitly)
- **Token refresh + WebView notification** — parity here is non-negotiable; a broken refresh
  logs the web layer out. Test an expired-access-token path end-to-end.
- **Lenient decoding** — the Realm `MediaProgress` uses `doubleOrStringDecoder` because the
  server has historically returned some numbers as strings. The generated decoder is strict
  and will throw on that. Confirm the server returns real numbers for these fields, or add a
  tolerant coding strategy, before trusting Phase 2/3.
- **Realm threading** — never mutate a persisted object off its thread; map to/from DTOs
  using frozen copies, write back inside a transaction.
- **Offline reconciliation** — the local-session merge logic is subtle; regression-test the
  "local newer than server" and "server newer than local" branches.
- **Server unreachable / partial failure** — mirror the current graceful degradation.

## Rollback
Because Phase 0 is additive and each later phase is endpoint-scoped, keep a feature flag (or
simply retain `ApiClient`) so any endpoint can fall back instantly. Don't delete `ApiClient`
until every phase above is proven on a real device against a real server.
