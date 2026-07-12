# ABSApiClient

A local Swift package that provides a **typed Audiobookshelf API client**, generated at
build time from an OpenAPI document using Apple's
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator).

It lives inside this repo (not a separate repo) so it evolves with the app and needs no
cross-repo coordination. If the client is ever useful to other apps or the community, this
directory can be lifted into its own repository unchanged.

## What's here

| File | Purpose |
|------|---------|
| `Package.swift` | Package manifest; wires in the generator plugin + runtime + URLSession transport. |
| `Sources/ABSApiClient/openapi.yaml` | The bundled OpenAPI spec the client is generated from. |
| `Sources/ABSApiClient/openapi-generator-config.yaml` | Generator config (`types` + `client`, public access). |
| `Sources/ABSApiClient/ABSApiClient.swift` | Hand-written convenience layer: `makeClient(serverURL:accessToken:)` + a bearer-auth middleware. |

`Client.swift` and `Types.swift` are **not** checked in — they are generated into the build
directory on every build. Regenerate simply by building.

## The OpenAPI spec

`openapi.yaml` is a self-contained bundle of the Audiobookshelf server's OpenAPI docs plus
the playback/auth/progress endpoints (`/auth/refresh`, `/api/me`, `/api/me/progress/*`,
`/api/items/{id}/play*`, `/api/session/*`). To refresh it from the server repo's `docs/`:

```bash
# from a checkout of advplyr/audiobookshelf
npx @redocly/cli bundle docs/root.yaml -o <path>/ios/ABSApiClient/Sources/ABSApiClient/openapi.yaml
```

## Verify it builds standalone

```bash
cd ios/ABSApiClient
swift build
```

This runs the generator plugin and compiles the generated client — no Xcode required.

## Using it

```swift
import ABSApiClient

let client = ABSApiClient.makeClient(
    serverURL: URL(string: serverConfig.address)!,
    accessToken: serverConfig.token
)

// Start a playback session (generated, typed):
let response = try await client.playLibraryItem(
    path: .init(id: libraryItemId),
    body: .json(.init(
        forceDirectPlay: "1",
        deviceInfo: .init(deviceId: deviceId, clientName: "Abs iOS", clientVersion: appVersion)
    ))
)
let session = try response.ok.body.json   // Components.Schemas.playbackSession

// Sync progress:
_ = try await client.syncPlaybackSession(
    path: .init(id: session.id!),
    body: .json(.init(currentTime: 1234, duration: 5678, timeListened: 30))
)
```

Every documented operation is available as a typed method (`getCurrentUser`,
`getMediaProgress`, `updateMediaProgress`, `playPodcastEpisode`, `syncLocalPlaybackSession`,
`syncAllLocalPlaybackSessions`, `refreshToken`, …), and every schema as a `Components.Schemas.*`
struct.

## Wiring into the `Audiobookshelf` app target (alongside CocoaPods)

The iOS app uses CocoaPods; SwiftPM and CocoaPods coexist fine in one Xcode project.

1. Open `ios/App/App.xcworkspace` in Xcode.
2. **File ▸ Add Package Dependencies… ▸ Add Local…** and select `ios/ABSApiClient`.
3. Add the `ABSApiClient` library product to the **Audiobookshelf** target
   (target ▸ General ▸ Frameworks, Libraries, and Embedded Content).
4. First build: Xcode will ask to **trust & enable** the `OpenAPIGenerator` build-tool
   plugin (plugin validation). Approve it — this is expected for build-tool plugins.
5. `import ABSApiClient` where needed.

### Command-line / CI builds

Headless `xcodebuild` cannot show the trust prompt and will fail with
`Validate plug-in "OpenAPIGenerator"`. Pass the skip flag so the build-tool plugin runs
unattended (safe: the plugin is a pinned, first-party Apple package):

```bash
xcodebuild -workspace ios/App/App.xcworkspace -scheme App \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation build
```

Add `-skipPackagePluginValidation` to the TestFlight/CI build invocation as well.

> Note: the package pulls its dependencies via SwiftPM (swift-openapi-runtime,
> swift-openapi-urlsession, and their transitive deps). These are independent of the
> Podfile — CocoaPods manages Alamofire/Realm/Capacitor as before.

## How this relates to the existing `ApiClient.swift`

This client is **additive**. It is intended first for *new* native surfaces that run outside
the WebView — CarPlay, Home/Lock-screen widgets, Siri Shortcuts — which need typed API access
that the JavaScript layer can't provide.

It is **not** a drop-in replacement for `ios/App/Shared/util/ApiClient.swift`: the generated
models (`Components.Schemas.playbackSession`, etc.) are plain `Codable` DTOs, whereas the
existing app models (`class PlaybackSession: Object`) are Realm-backed. Migrating the existing
player/download paths would require mapping generated DTOs ↔ Realm models and can be done
incrementally, later — it is out of scope for the initial adoption.
