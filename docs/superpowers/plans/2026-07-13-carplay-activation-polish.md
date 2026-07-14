# CarPlay Activation + Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the already-built CarPlay thin slice (now that Apple granted the `carplay-audio` entitlement) and add library switching, on-screen search, and correct cover / Now Playing artwork — without black-screening the phone app.

**Architecture:** Add the CarPlay `UIScene` via a **dual-role** `UIApplicationSceneManifest` (window role backed by `Main.storyboard` + CarPlay role → `CarPlaySceneDelegate`), so the existing Capacitor AppDelegate window keeps working. Replace `CarPlayManager`'s single-list root with a `CPTabBarTemplate` (Home / Library / Search). Reuse the existing `Browse*` layer and App Intents Siri path. Cover fixes force `format=jpeg` (server WebP decodes unreliably) and size list art to `CPListItem.maximumImageSize`.

**Tech Stack:** Swift, CarPlay framework (`CPTabBarTemplate`, `CPListTemplate`, `CPSearchTemplate`, `CPNowPlayingTemplate`), MediaPlayer (`MPNowPlayingInfoCenter`), the local `ABSApiClient` SPM package, Realm (`Database`), XCTest.

## Global Constraints

- Branch: `feat/sdk-browse-endpoints`. Keep every commit upstream-mergeable (no local signing team, no `com.audiobookshelfngo.app` leaks).
- `project.pbxproj` is `assume-unchanged` with a local signing override — **never plain `git add` it**. Use the **commit-xcodeproj-changes** skill for any pbxproj change (Task 2).
- Server sources must stay failure-tolerant: any offline/decode error yields `[]`, never a crash; the on-device **Downloads** section must always render.
- Server cover URLs must force `?format=jpeg` (server default WebP decodes unreliably via `UIImage(data:)`).
- CarPlay lists must respect `CPListTemplate.maximumItemCount` at runtime (as low as 12 while driving) — never assume a fixed count.
- Pure mappers/helpers go under `ios/App/Shared/util/browse/` and are unit-tested in `AudiobookshelfUnitTests`; CarPlay-framework code goes under `ios/App/App/carplay/` and is verified on the CarPlay Simulator.
- Unit test command (from repo root):
  `xcodebuild test -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:AudiobookshelfUnitTests` (or the `mcp__xcode` `test_sim` tool with the session defaults). Adjust the simulator name to one from `xcrun simctl list devices available`.

---

### Task 1: Dual-role scene manifest + phone-window gate

The critical, must-pass-first task. A CarPlay-*only* manifest black-screens the phone (confirmed). Declaring the window role too keeps the phone window.

**Files:**
- Modify: `ios/App/App/Info.plist` (add `UIApplicationSceneManifest`)

**Interfaces:**
- Consumes: existing `CarPlaySceneDelegate` (`ios/App/App/carplay/CarPlaySceneDelegate.swift`), existing `Main` storyboard.
- Produces: a running CarPlay scene role; phone app still launches from `Main.storyboard`.

- [ ] **Step 1: Add the scene manifest to Info.plist**

Insert this block inside the top-level `<dict>` of `ios/App/App/Info.plist` (e.g. just after the `CFBundleURLTypes` array):

```xml
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<true/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>UIWindowSceneSessionRoleApplication</key>
			<array>
				<dict>
					<key>UISceneConfigurationName</key>
					<string>Default Configuration</string>
					<key>UISceneStoryboardFile</key>
					<string>Main</string>
				</dict>
			</array>
			<key>CPTemplateApplicationSceneSessionRoleApplication</key>
			<array>
				<dict>
					<key>UISceneConfigurationName</key>
					<string>CarPlay Configuration</string>
					<key>UISceneDelegateClassName</key>
					<string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
				</dict>
			</array>
		</dict>
	</dict>
```

- [ ] **Step 2: Build + launch the phone app on the simulator**

Run (or use `mcp__xcode` `build_run_sim` with session defaults):
`xcodebuild build -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15'`
then launch the app in the booted simulator.

Expected: the app launches to its **full home screen** (WebView UI), NOT a black screen with only the status bar.

- [ ] **Step 3: Decision gate**

- If the phone app launches normally → continue to Step 4.
- If it black-screens (double-window / empty window) → **abandon Approach A, switch to Approach B**: revert this Info.plist to declare ONLY the CarPlay role's config name but WITHOUT `UISceneStoryboardFile`, and implement in `ios/App/App/AppDelegate.swift`:

```swift
func application(_ application: UIApplication,
                 configurationForConnecting connectingSceneSession: UISceneSession,
                 options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    if connectingSceneSession.role == .carTemplateApplication {
        let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = CarPlaySceneDelegate.self
        return config
    }
    return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
}
```
Re-run Step 2 until the phone window launches. Record which approach worked in the commit message.

- [ ] **Step 4: Smoke-test the window-sensitive flows**

In the simulator, verify (these all touch the window/launch path that the manifest changes):
1. Cold launch → home screen renders.
2. Custom-scheme deep link still opens (e.g. widget resume URL `audiobookshelf://...`).
3. Rotate the device → UI reflows (no black screen).

Expected: all unchanged from before the manifest.

- [ ] **Step 5: Commit**

```bash
git add ios/App/App/Info.plist ios/App/App/AppDelegate.swift
git commit -m "feat(ios): add dual-role scene manifest so CarPlay scene loads without black-screening the phone (#475)"
```

---

### Task 2: Re-add carplay-audio entitlement + wire code signing

**Files:**
- Modify: `ios/App/App/App.entitlements` (add `carplay-audio`)
- Modify: `ios/App/App.xcodeproj/project.pbxproj` (set `CODE_SIGN_ENTITLEMENTS`) — **via commit-xcodeproj-changes skill**

**Interfaces:**
- Consumes: nothing.
- Produces: a CarPlay-capable signed build; CarPlay scene can instantiate on device + sim.

- [ ] **Step 1: Add the entitlement key**

Edit `ios/App/App/App.entitlements` so the `<dict>` also contains (keep the existing `application-groups` array):

```xml
	<key>com.apple.developer.carplay-audio</key>
	<true/>
```

- [ ] **Step 2: Wire CODE_SIGN_ENTITLEMENTS (skill)**

Invoke the **commit-xcodeproj-changes** skill. Set `CODE_SIGN_ENTITLEMENTS = App/App.entitlements` for the **App** target's Debug and Release build configs if not already set (check first with `grep -n CODE_SIGN_ENTITLEMENTS ios/App/App.xcodeproj/project.pbxproj`). The skill handles the `assume-unchanged` dance so the local signing team does not leak.

- [ ] **Step 3: Build to confirm signing**

Run: `xcodebuild build -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED (sim build ignores the provisioning profile; device signing needs the granted entitlement in the profile — note for the fastlane pipeline, out of scope here).

- [ ] **Step 4: Commit the entitlements file**

```bash
git add ios/App/App/App.entitlements
git commit -m "feat(ios): enable com.apple.developer.carplay-audio entitlement (#475)"
```
(The pbxproj commit is produced by the skill in Step 2.)

---

### Task 3: Section model + item-count capping helper (TDD)

Introduce a small `BrowseSection` value type and a pure capping function so every CarPlay list respects `maximumItemCount`. Pure and unit-tested; no CarPlay import.

**Files:**
- Create: `ios/App/Shared/util/browse/BrowseSection.swift`
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseSectionTests.swift`

**Interfaces:**
- Consumes: `BrowseItem` (`ios/App/Shared/util/browse/BrowseItem.swift`).
- Produces:
  - `struct BrowseSection: Equatable { let header: String; let items: [BrowseItem] }`
  - `static func BrowseSection.capped(_ sections: [BrowseSection], maxItems: Int) -> [BrowseSection]` — trims to at most `maxItems` total items, filling sections in order, dropping sections that become empty; `maxItems <= 0` yields `[]`.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseSectionTests.swift`:

```swift
import XCTest
@testable import Audiobookshelf

final class BrowseSectionTests: XCTestCase {
    private func item(_ id: String) -> BrowseItem {
        BrowseItem(id: id, title: id, author: nil, isLocal: false, coverURL: nil)
    }
    private func section(_ header: String, _ ids: [String]) -> BrowseSection {
        BrowseSection(header: header, items: ids.map(item))
    }

    func testUnderBudgetUnchanged() {
        let input = [section("A", ["1", "2"]), section("B", ["3"])]
        XCTAssertEqual(BrowseSection.capped(input, maxItems: 12), input)
    }

    func testTrimsAcrossSectionsInOrder() {
        let input = [section("A", ["1", "2", "3"]), section("B", ["4", "5"])]
        let out = BrowseSection.capped(input, maxItems: 4)
        XCTAssertEqual(out, [section("A", ["1", "2", "3"]), section("B", ["4"])])
    }

    func testDropsSectionThatBecomesEmpty() {
        let input = [section("A", ["1", "2", "3"]), section("B", ["4", "5"])]
        let out = BrowseSection.capped(input, maxItems: 3)
        XCTAssertEqual(out, [section("A", ["1", "2", "3"])])
    }

    func testZeroBudgetYieldsEmpty() {
        XCTAssertTrue(BrowseSection.capped([section("A", ["1"])], maxItems: 0).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:AudiobookshelfUnitTests/BrowseSectionTests`
Expected: FAIL — `BrowseSection` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `ios/App/Shared/util/browse/BrowseSection.swift`:

```swift
//
//  BrowseSection.swift
//  App
//
//  A titled group of BrowseItems plus the pure capping used to honor CarPlay's runtime
//  CPListTemplate.maximumItemCount (as low as 12 while driving). Kept free of the CarPlay
//  framework so it is unit-testable.
//

import Foundation

struct BrowseSection: Equatable {
    let header: String
    let items: [BrowseItem]
}

extension BrowseSection {
    /// Trim `sections` so their combined item count is at most `maxItems`, filling sections in
    /// order and dropping any section left empty. `maxItems <= 0` yields no sections.
    static func capped(_ sections: [BrowseSection], maxItems: Int) -> [BrowseSection] {
        guard maxItems > 0 else { return [] }
        var remaining = maxItems
        var result: [BrowseSection] = []
        for section in sections {
            guard remaining > 0 else { break }
            let take = Array(section.items.prefix(remaining))
            guard !take.isEmpty else { continue }
            result.append(BrowseSection(header: section.header, items: take))
            remaining -= take.count
        }
        return result
    }
}
```

Register the new files in the Xcode targets: `BrowseSection.swift` → **App** target, `BrowseSectionTests.swift` → **AudiobookshelfUnitTests** target. This edits `project.pbxproj` — use the **commit-xcodeproj-changes** skill for that pbxproj change.

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/App/Shared/util/browse/BrowseSection.swift ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseSectionTests.swift
git commit -m "feat(ios): BrowseSection + maximumItemCount capping helper (#475)"
```
(pbxproj target registration is committed via the skill.)

---

### Task 4: BrowseApi.bookLibraries() + BrowseLibrary mapper (TDD)

The Library tab needs the server's book libraries with names. Add a pure decoder (tested) and the async fetch (thin, over the existing `fetchLibrariesData`).

**Files:**
- Create: `ios/App/Shared/util/browse/BrowseLibrary.swift`
- Modify: `ios/App/Shared/util/browse/BrowseApi.swift` (add `bookLibraries()`)
- Test: `ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseLibraryTests.swift`

**Interfaces:**
- Consumes: `ABSApiClient.fetchLibrariesData(config:)` (`ios/ABSApiClient/.../ABSApiClientOperations.swift`), `ABSClientProvider.config`.
- Produces:
  - `struct BrowseLibrary: Equatable { let id: String; let name: String }`
  - `static func BrowseLibrary.fromLibraries(data: Data) -> [BrowseLibrary]` — book libraries only, drop entries missing id/name.
  - `static func BrowseApi.bookLibraries() async -> [BrowseLibrary]` — `[]` on failure.

- [ ] **Step 1: Write the failing test**

Create `ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseLibraryTests.swift`:

```swift
import XCTest
@testable import Audiobookshelf

final class BrowseLibraryTests: XCTestCase {
    func testKeepsBookLibrariesOnly() {
        let json = Data("""
        { "libraries": [
            { "id": "lib_b", "name": "Books", "mediaType": "book" },
            { "id": "lib_p", "name": "Podcasts", "mediaType": "podcast" },
            { "id": "lib_b2", "name": "Sci-Fi", "mediaType": "book" }
        ] }
        """.utf8)
        XCTAssertEqual(BrowseLibrary.fromLibraries(data: json),
                       [BrowseLibrary(id: "lib_b", name: "Books"),
                        BrowseLibrary(id: "lib_b2", name: "Sci-Fi")])
    }

    func testDropsEntriesMissingIdOrName() {
        let json = Data("""
        { "libraries": [
            { "name": "No ID", "mediaType": "book" },
            { "id": "lib_ok", "name": "OK", "mediaType": "book" },
            { "id": "lib_noname", "mediaType": "book" }
        ] }
        """.utf8)
        XCTAssertEqual(BrowseLibrary.fromLibraries(data: json).map(\.id), ["lib_ok"])
    }

    func testMalformedYieldsEmpty() {
        XCTAssertTrue(BrowseLibrary.fromLibraries(data: Data("nope".utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:AudiobookshelfUnitTests/BrowseLibraryTests`
Expected: FAIL — `BrowseLibrary` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `ios/App/Shared/util/browse/BrowseLibrary.swift`:

```swift
//
//  BrowseLibrary.swift
//  App
//
//  A pure view model for one server book library, used by the CarPlay Library tab. Lenient decode
//  over GET /api/libraries; podcast libraries and entries missing id/name are dropped.
//

import Foundation

struct BrowseLibrary: Equatable {
    let id: String
    let name: String
}

extension BrowseLibrary {
    private struct Response: Decodable {
        let libraries: [Entry]?
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let mediaType: String?
        }
    }

    static func fromLibraries(data: Data) -> [BrowseLibrary] {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.libraries ?? []).compactMap { entry in
            guard entry.mediaType == "book",
                  let id = entry.id, !id.isEmpty,
                  let name = entry.name, !name.isEmpty else { return nil }
            return BrowseLibrary(id: id, name: name)
        }
    }
}
```

Add to `ios/App/Shared/util/browse/BrowseApi.swift` (inside `enum BrowseApi`):

```swift
    /// The user's book libraries (id + name) for the CarPlay Library tab. [] on failure.
    static func bookLibraries() async -> [BrowseLibrary] {
        guard let config = ABSClientProvider.config else { return [] }
        guard let data = await ABSApiClient.fetchLibrariesData(config: config) else { return [] }
        return BrowseLibrary.fromLibraries(data: data)
    }
```

Register `BrowseLibrary.swift` → App target and `BrowseLibraryTests.swift` → AudiobookshelfUnitTests target (commit-xcodeproj-changes skill).

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/App/Shared/util/browse/BrowseLibrary.swift ios/App/Shared/util/browse/BrowseApi.swift ios/App/AudiobookshelfUnitTests/Shared/util/browse/BrowseLibraryTests.swift
git commit -m "feat(ios): BrowseApi.bookLibraries() for CarPlay library switching (#475)"
```

---

### Task 5: CPTabBarTemplate root + shared row mapper (Home tab)

Refactor `CarPlayManager` so its root is a `CPTabBarTemplate`, extract the `BrowseItem → CPListItem` mapper (reused by search), route Home through `BrowseSection.capped`, and drive Home's Recently Added from an active-library id.

**Files:**
- Modify: `ios/App/App/carplay/CarPlayManager.swift`

**Interfaces:**
- Consumes: `BrowseApi.continueListening/recentlyAdded/downloads/firstBookLibraryId`, `BrowseSection`, `BrowseItem`, `BrowsePlaybackStarter`, `ApiClient.getData`, `CPListTemplate.maximumItemCount`.
- Produces (used by Tasks 6 & 7):
  - `func makeRow(_ item: BrowseItem) -> CPListItem` (mapper; loads cover, handles selection → play → push Now Playing)
  - `var activeLibraryId: String?` (set by the Library tab)
  - `func rebuildHome()` (reloads the Home tab's sections)
  - `let interfaceController: CPInterfaceController` (accessible to sibling controllers)

- [ ] **Step 1: Replace CarPlayManager with the tab-bar version**

Rewrite `ios/App/App/carplay/CarPlayManager.swift`:

```swift
//
//  CarPlayManager.swift
//  App
//
//  Builds and drives the CarPlay UI: a tab bar with Home (Continue Listening / Recently Added /
//  Downloads), Library (switch which server library feeds Recently Added), and Search. Server
//  sections are best-effort — offline they are omitted, leaving the always-available Downloads
//  section. All lists honor CPListTemplate.maximumItemCount.
//

import CarPlay
import UIKit

final class CarPlayManager {
    let interfaceController: CPInterfaceController
    private let tabBar = CPTabBarTemplate(templates: [])
    private let homeTemplate = CPListTemplate(title: "Home", sections: [])

    private var libraryController: CarPlayLibraryController?
    private var searchController: CarPlaySearchController?

    /// The library whose "Recently Added" shelf feeds Home. Defaults to the first book library.
    var activeLibraryId: String?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        let library = CarPlayLibraryController(manager: self)
        let search = CarPlaySearchController(manager: self)
        self.libraryController = library
        self.searchController = search

        tabBar.updateTemplates([homeTemplate, library.template, search.template])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        rebuildHome()
    }

    // MARK: - Home

    func rebuildHome() {
        Task {
            if activeLibraryId == nil { activeLibraryId = await BrowseApi.firstBookLibraryId() }
            let continueListening = await BrowseApi.continueListening()
            var recentlyAdded: [BrowseItem] = []
            if let libraryId = activeLibraryId {
                recentlyAdded = await BrowseApi.recentlyAdded(libraryId: libraryId)
            }
            let downloads = BrowseApi.downloads()

            var sections = [
                BrowseSection(header: "Continue Listening", items: continueListening),
                BrowseSection(header: "Recently Added", items: recentlyAdded),
                BrowseSection(header: "Downloads", items: downloads),
            ].filter { !$0.items.isEmpty }
            sections = BrowseSection.capped(sections, maxItems: CPListTemplate.maximumItemCount)

            let listSections = sections.map {
                CPListSection(items: $0.items.map(makeRow), header: $0.header, sectionIndexTitle: nil)
            }
            let final = listSections.isEmpty
                ? [CPListSection(items: [CPListItem(text: "Nothing to play", detailText: nil)])]
                : listSections
            await MainActor.run { self.homeTemplate.updateSections(final) }
        }
    }

    // MARK: - Row mapping (shared with search)

    func makeRow(_ item: BrowseItem) -> CPListItem {
        let row = CPListItem(text: item.title, detailText: item.author)
        row.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in
                BrowsePlaybackStarter.play(item) {
                    self?.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
            }
        }
        loadCover(item, into: row)
        return row
    }

    private func loadCover(_ item: BrowseItem, into row: CPListItem) {
        guard let url = item.coverURL else { return }
        ApiClient.getData(from: url) { [weak self] image in
            guard let image = image else { return }
            let sized = self?.sizedCover(image) ?? image
            DispatchQueue.main.async { row.setImage(sized) }
        }
    }

    /// Placeholder until Task 8 sizes to CPListItem.maximumImageSize.
    private func sizedCover(_ image: UIImage) -> UIImage { image }
}
```

> NOTE: this references `CarPlayLibraryController` and `CarPlaySearchController`, added in Tasks 6 & 7. To keep this task independently compilable, first add minimal stub files (below) so the app builds; Tasks 6 & 7 flesh them out.

Create stub `ios/App/App/carplay/CarPlayLibraryController.swift`:

```swift
import CarPlay

final class CarPlayLibraryController {
    let template = CPListTemplate(title: "Library", sections: [])
    private weak var manager: CarPlayManager?
    init(manager: CarPlayManager) { self.manager = manager }
}
```

Create stub `ios/App/App/carplay/CarPlaySearchController.swift`:

```swift
import CarPlay

final class CarPlaySearchController {
    let template = CPListTemplate(title: "Search", sections: [])
    private weak var manager: CarPlayManager?
    init(manager: CarPlayManager) { self.manager = manager }
}
```

Register both new files → App target (commit-xcodeproj-changes skill).

- [ ] **Step 2: Build the app**

Run: `xcodebuild build -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify on the CarPlay Simulator**

Boot the sim, launch the app, open Xcode Simulator → **I/O → External Displays → CarPlay**. Sign in to a server if needed.
Expected: a **tab bar** with Home / Library / Search; Home shows Continue Listening / Recently Added / Downloads (whichever are non-empty), tapping a Home row starts playback and pushes the Now Playing screen.

- [ ] **Step 4: Commit**

```bash
git add ios/App/App/carplay/CarPlayManager.swift ios/App/App/carplay/CarPlayLibraryController.swift ios/App/App/carplay/CarPlaySearchController.swift
git commit -m "feat(ios): CarPlay CPTabBarTemplate root + shared row mapper + item capping (#475)"
```

---

### Task 6: Library tab (switch active library)

**Files:**
- Modify: `ios/App/App/carplay/CarPlayLibraryController.swift`

**Interfaces:**
- Consumes: `BrowseApi.bookLibraries()` (Task 4), `CarPlayManager` (`activeLibraryId`, `rebuildHome()`).
- Produces: a `CPListTemplate` of book libraries; selecting one sets `manager.activeLibraryId` and rebuilds Home.

- [ ] **Step 1: Implement the controller**

Replace `ios/App/App/carplay/CarPlayLibraryController.swift`:

```swift
//
//  CarPlayLibraryController.swift
//  App
//
//  The CarPlay "Library" tab: lists the server's book libraries; selecting one switches which
//  library feeds Home's Recently Added shelf. Offline/error shows a single disabled row; Home
//  still works from Downloads.
//

import CarPlay

final class CarPlayLibraryController {
    let template = CPListTemplate(title: "Library", sections: [])
    private weak var manager: CarPlayManager?

    init(manager: CarPlayManager) {
        self.manager = manager
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "books.vertical")
        reload()
    }

    private func reload() {
        Task {
            let libraries = await BrowseApi.bookLibraries()
            let items: [CPListItem] = libraries.map { library in
                let row = CPListItem(text: library.name, detailText: nil)
                row.handler = { [weak self] _, completion in
                    completion()
                    self?.manager?.activeLibraryId = library.id
                    self?.manager?.rebuildHome()
                    self?.manager?.interfaceController.selectTabTemplateAtIndex?(0) // back to Home if supported
                }
                return row
            }
            let section = items.isEmpty
                ? CPListSection(items: [CPListItem(text: "Libraries unavailable", detailText: nil)])
                : CPListSection(items: items)
            await MainActor.run { self.template.updateSections([section]) }
        }
    }
}
```

> If `selectTabTemplateAtIndex` is unavailable on the deployment target, drop that line — switching library + `rebuildHome()` is the required behavior; auto-returning to Home is a nicety.

- [ ] **Step 2: Build**

Run the Task 5 Step 2 build command. Expected: BUILD SUCCEEDED. (If `selectTabTemplateAtIndex` fails to compile, remove that line and rebuild.)

- [ ] **Step 3: Verify on CarPlay Simulator**

Open the Library tab → book libraries listed. Tap one → Home's Recently Added reflects that library. Kill the network → Library tab shows "Libraries unavailable"; Home still shows Downloads.

- [ ] **Step 4: Commit**

```bash
git add ios/App/App/carplay/CarPlayLibraryController.swift
git commit -m "feat(ios): CarPlay Library tab switches the active library (#475)"
```

---

### Task 7: Search tab (CPSearchTemplate)

**Files:**
- Modify: `ios/App/App/carplay/CarPlaySearchController.swift`

**Interfaces:**
- Consumes: `BrowseApi.search(query:)`, `CarPlayManager` (`makeRow`, `interfaceController`), `BrowseSection.capped`.
- Produces: a `CPSearchTemplate`-backed Search tab. NOTE: `CarPlayManager.start()` puts `searchController.template` (a `CPListTemplate` acting as the tab) in the tab bar; that list's single row pushes the `CPSearchTemplate`, because `CPSearchTemplate` cannot itself be a tab.

- [ ] **Step 1: Implement the controller**

Replace `ios/App/App/carplay/CarPlaySearchController.swift`:

```swift
//
//  CarPlaySearchController.swift
//  App
//
//  The CarPlay "Search" tab. The tab itself is a CPListTemplate with a single "Search" row that
//  presents a CPSearchTemplate (CPSearchTemplate cannot be a tab). Results reuse the manager's
//  shared row mapper and honor maximumItemCount.
//

import CarPlay

final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
    let template: CPListTemplate
    private weak var manager: CarPlayManager?
    private let searchTemplate = CPSearchTemplate()

    init(manager: CarPlayManager) {
        self.manager = manager
        let entry = CPListItem(text: "Search", detailText: nil)
        self.template = CPListTemplate(title: "Search", sections: [CPListSection(items: [entry])])
        super.init()
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        searchTemplate.delegate = self
        entry.handler = { [weak self] _, completion in
            completion()
            guard let self = self else { return }
            self.manager?.interfaceController.pushTemplate(self.searchTemplate, animated: true, completion: nil)
        }
    }

    // Debounce so we don't fire a search per keystroke.
    private var pendingSearch: Task<Void, Never>?

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        pendingSearch?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { completionHandler([]); return }
        pendingSearch = Task {
            let results = await BrowseApi.search(query: query)
            let capped = Array(results.prefix(CPListTemplate.maximumItemCount))
            let rows = await MainActor.run { capped.map { self.manager?.makeRow($0) ?? CPListItem(text: $0.title, detailText: $0.author) } }
            if Task.isCancelled { return }
            completionHandler(rows)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        // Row handlers (from makeRow) already start playback + push Now Playing.
        item.handler?(item, completionHandler) ?? completionHandler()
    }
}
```

- [ ] **Step 2: Build**

Run the Task 5 Step 2 build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify on CarPlay Simulator**

Open the Search tab → tap "Search" → the CarPlay search UI appears; typing (or the car's dictation button) returns matching books; selecting one plays and shows Now Playing.

- [ ] **Step 4: Commit**

```bash
git add ios/App/App/carplay/CarPlaySearchController.swift
git commit -m "feat(ios): CarPlay Search tab via CPSearchTemplate over BrowseApi.search (#475)"
```

---

### Task 8: Size list covers to CPListItem.maximumImageSize

**Files:**
- Modify: `ios/App/App/carplay/CarPlayManager.swift` (`sizedCover`)

**Interfaces:**
- Consumes: `interfaceController.carTraitCollection.displayScale`, `CPListItem.maximumImageSize`.
- Produces: replaces the placeholder `sizedCover` with a real square-crop + resize.

- [ ] **Step 1: Implement sizedCover**

Replace the placeholder `sizedCover` in `CarPlayManager.swift`:

```swift
    /// Crop to a centered square and resize to CPListItem.maximumImageSize at the car's display
    /// scale, so covers render crisply without shipping oversized bitmaps to the head unit.
    private func sizedCover(_ image: UIImage) -> UIImage {
        let maxPoints = CPListItem.maximumImageSize
        guard maxPoints.width > 0, maxPoints.height > 0 else { return image }
        let scale = interfaceController.carTraitCollection.displayScale
        let side = min(image.size.width, image.size.height)
        let cropRect = CGRect(
            x: (image.size.width - side) / 2,
            y: (image.size.height - side) / 2,
            width: side, height: side)
        guard let cg = image.cgImage?.cropping(to: cropRect) else { return image }
        let square = UIImage(cgImage: cg)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: maxPoints, format: format)
        return renderer.image { _ in square.draw(in: CGRect(origin: .zero, size: maxPoints)) }
    }
```

- [ ] **Step 2: Build**

Run the Task 5 Step 2 build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify on CarPlay Simulator**

Home / search rows show crisp, square covers (not stretched, not oversized).

- [ ] **Step 4: Commit**

```bash
git add ios/App/App/carplay/CarPlayManager.swift
git commit -m "feat(ios): size CarPlay list covers to CPListItem.maximumImageSize (#475)"
```

---

### Task 9: Fix Now Playing artwork (force format=jpeg)

The server cover URL in `NowPlayingInfo` omits `format=jpeg`, so the default WebP fails to decode via `UIImage(data:)` and no artwork shows on CarPlay Now Playing / the lock screen. Force jpeg (the same trick `BrowseItem` uses).

**Files:**
- Modify: `ios/App/Shared/util/NowPlayingInfo.swift:26-34` (server `coverUrlString`)

**Interfaces:**
- Consumes: nothing new.
- Produces: a decodable jpeg cover for `MPMediaItemArtwork`.

- [ ] **Step 1: Add format=jpeg to the server cover URL**

In `NowPlayingInfo.swift`, change the server branch of `NowPlayingMetadata.coverUrl` so both variants request jpeg:

```swift
            // As of v2.17.0 token is not needed with cover image requests. Force JPEG because the
            // server's default WebP decodes unreliably via UIImage(data:), leaving Now Playing artless.
            let coverUrlString: String
            if Store.isServerVersionGreaterThanOrEqualTo("2.17.0") {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover?format=jpeg"
            } else {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover?token=\(config.token)&format=jpeg"
            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify artwork appears**

Play a **streaming** (non-downloaded) server book. Confirm the cover shows on the CarPlay Now Playing screen AND the iOS lock screen / Control Center. (Downloaded books already used the on-disk cover.)

- [ ] **Step 4: Commit**

```bash
git add ios/App/Shared/util/NowPlayingInfo.swift
git commit -m "fix(ios): force JPEG cover for Now Playing artwork so WebP no longer drops it (#475)"
```

---

### Task 10: End-to-end CarPlay + Siri verification

No code; a scripted manual pass that gates the branch. Record results in the commit or a note.

**Files:** none.

- [ ] **Step 1: Full unit suite**

Run: `xcodebuild test -workspace ios/App/App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:AudiobookshelfUnitTests`
Expected: PASS (BrowseItemTests + BrowseSectionTests + BrowseLibraryTests).

- [ ] **Step 2: CarPlay Simulator pass**

In CarPlay Simulator, verify: tab bar (Home/Library/Search); Home sections + play → Now Playing with cover; Library switch changes Recently Added; Search returns + plays; offline (network off) → Downloads-only, no crash.

- [ ] **Step 3: Siri from CarPlay**

With CarPlay connected in the sim (or a device), invoke Siri: **"Play &lt;book title&gt; in Audiobookshelf."**
Expected: resolves the spoken title via `BrowseApi.search`, starts playback, shows Now Playing. If it does NOT fire while docked, capture the behavior and open a follow-up (out of scope to fix here).

- [ ] **Step 4: Phone regression re-check**

Confirm (from Task 1, but re-verify after all changes): phone app launches, deep-link/widget resume works, rotation works.

- [ ] **Step 5: Commit the plan-completion note**

```bash
git commit --allow-empty -m "chore(ios): CarPlay activation + polish verified (browse/library/search/artwork/Siri) (#475)"
```

---

## Self-Review

**Spec coverage:**
- §1 scene wiring (Approach A + B fallback) → Task 1. ✓
- §2 CPTabBarTemplate + library switching + runtime item caps → Tasks 3, 4, 5, 6. ✓
- §3 verify Siri + CPSearchTemplate → Tasks 7, 10 (Step 3). ✓
- §4 list covers + Now Playing artwork → Tasks 8, 9. ✓
- §5 entitlement + provisioning → Task 2. ✓
- §6 verification ladder → phone gate in Task 1, units in Tasks 3/4/10, CarPlay sim + Siri in Task 10. ✓

**Placeholder scan:** No TBD/TODO. The intentional stub in Task 5 (`CarPlayLibraryController`/`CarPlaySearchController`) is explicitly labelled and fleshed out in Tasks 6/7 so Task 5 compiles independently. The Task-5 `sizedCover` returns the image unchanged and is explicitly marked "Placeholder until Task 8".

**Type consistency:** `BrowseSection`/`BrowseSection.capped` (Task 3) used identically in Task 5. `BrowseLibrary`/`BrowseApi.bookLibraries()` (Task 4) used in Task 6. `CarPlayManager.makeRow` / `interfaceController` / `activeLibraryId` / `rebuildHome()` produced in Task 5, consumed in Tasks 6/7/8. `sizedCover` defined in Task 5, replaced in Task 8. Consistent.

**Known risk to watch during execution:** `CPListTemplate.maximumItemCount` and `CPListItem.maximumImageSize` are static CarPlay APIs — if a target-OS variance surfaces, read them off the live template/`carTraitCollection` instead; the pure capping logic (Task 3) is unaffected. `selectTabTemplateAtIndex` in Task 6 is optional and guarded.
