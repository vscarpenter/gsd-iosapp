# Mac Catalyst (GSD on Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the GSD app as a Mac Catalyst build to TestFlight/App Store under the existing App Store Connect record, reusing all of `GSDKit` and the existing iPad layout, with basic Mac-native polish (menu bar + window sizing).

**Architecture:** The port is shell-level. `GSDKit` (model/store/sync/snapshot) already compiles for macOS — GRDB, Foundation, and the App-Group snapshot store are platform-clean, and `StoreLocation` already falls back gracefully when the App-Group container is absent. The work is confined to (1) `project.yml` Catalyst configuration, (2) two small `#if targetEnvironment(macCatalyst)` code guards, (3) Mac menu-bar/window polish that reuses the existing `DeepLinkRoute` routing, and (4) a parallel Mac archive/upload path in the release script. The two extensions (Widgets, Share) stay **iOS-only** and are excluded from the Catalyst build via a dependency `platformFilter`.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen (`project.yml` is source of truth), Mac Catalyst, `xcodebuild`, App Store Connect API key (already wired in `scripts/release.sh`).

**Scope (locked during scoping):** Main app only (extensions iOS-only) · ship to TestFlight/App Store · include basic Mac polish (menu bar commands + min window size).

**Out of scope (explicit):** Widgets on Mac, Share Extension on Mac, native AppKit rewrite, pointer/hover affordances on every row.

---

## Files

**Modify:**
- `project.yml` — add Catalyst build settings + Catalyst entitlements override on the `GSD` app target; add `platformFilter: iOS` to the two embedded-extension dependencies.
- `App/Background/BackgroundRefresh.swift` — guard `BGTaskScheduler` use out of the Catalyst build.
- `App/Settings/SettingsView.swift` — Catalyst branch for the "Open Settings" button (iOS Settings URL is meaningless on Mac).
- `App/Routing/DeepLinkHandoff.swift` — add a `.gsdShowCommandPalette` notification name.
- `App/ContentView.swift` — observe `.gsdShowCommandPalette`; gate the duplicate hidden ⌘-shortcut buttons off on Catalyst.
- `App/GSDApp.swift` — attach Catalyst-only `.commands { GSDMenuCommands() }`.
- `App/Routing/QuickActions.swift` — set a Catalyst minimum window size in the existing scene delegate.
- `scripts/release.sh` — add a `--mac` flag that archives/exports/uploads the Catalyst app.

**Create:**
- `App/GSD-Catalyst.entitlements` — sandbox + network-client + file-access + App Group, used only for the `macosx` SDK build.
- `App/Mac/GSDMenuCommands.swift` — the Mac menu-bar command tree, routing through existing `DeepLinkRoute`s.
- `ExportOptions-Mac.plist` — `app-store-connect` export options for the Mac binary.

**Reference (read, do not change):**
- `GSDKit/Sources/GSDStore/StoreLocation.swift` — App-Group container resolution + Application-Support fallback (why provisioning gaps don't crash launch).
- `GSDKit/Sources/GSDSnapshot/DeepLink.swift` — `DeepLinkRoute` cases (`focus`, `capture`, `quadrant`, `dashboard`, `settings`, `archive`, …) and `.url`.
- `GSDKit/Sources/GSDModel/Quadrant.swift` — `Quadrant.title` (used for menu labels; Q1 Do First … Q4 Eliminate).

---

## Conventions for this plan

This is a configuration/integration plan, not unit-test-driven feature work. There is no app-layer unit-test target (per `CLAUDE.md`, app glue is verified by **build + smoke**; logic is verified by `cd GSDKit && swift test`). So the per-task "test" is a **Catalyst build** and, where relevant, a **launch smoke check**. The canonical commands:

```bash
# Regenerate the Xcode project after any project.yml edit (ALWAYS run this first).
xcodegen generate

# Build for Mac Catalyst into a predictable derived-data path.
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/dd build

# Launch the built Catalyst app for a smoke check.
open build/dd/Build/Products/Debug-maccatalyst/GSD.app

# iOS regression gate — the iPhone/iPad build must STILL pass after every task.
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

> Every task ends by confirming the **iOS build is unbroken** — this work must not regress the shipping iPhone/iPad app.

---

## Task 1: Configure Mac Catalyst in `project.yml`

**Files:**
- Modify: `project.yml` (GSD app target `settings.base`, and the two embed dependencies)
- Create: `App/GSD-Catalyst.entitlements`

**Why a separate Catalyst entitlements file:** macOS App-Sandbox keys (`com.apple.security.app-sandbox`, `…network.client`) are **not** valid iOS entitlements — putting them in the shared `App/GSD.entitlements` risks an iOS provisioning/validation failure. The `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` override applies the Catalyst entitlements only to the macOS-SDK (Catalyst) build, leaving the iOS build on the existing clean file.

**Why `platformFilter: iOS` on the extensions:** the GSD app embeds `GSDWidgets` and `GSDShareExtension`, both `platform: iOS`. A Catalyst build would otherwise try to build/embed iOS-only `.appex`es and fail. `platformFilter: iOS` excludes them from the Catalyst (macOS) build entirely — matching the "main app only" scope without touching the extension targets.

- [ ] **Step 1: Create the Catalyst entitlements file**

Create `App/GSD-Catalyst.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <!-- Outbound sync: PocketBase REST + SSE. -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Import/export document pickers reach user-chosen files. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- Same App Group as iOS — Catalyst uses the iOS-style `group.` identifier. -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.dev.vinny.gsd</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Add Catalyst build settings to the GSD app target**

In `project.yml`, under `targets: → GSD: → settings: → base:`, add the three Catalyst keys alongside the existing entries. The block becomes:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.vinny.gsd
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "NO"
        CODE_SIGN_ENTITLEMENTS: App/GSD.entitlements
        CODE_SIGN_STYLE: Automatic
        # --- Mac Catalyst ---
        SUPPORTS_MACCATALYST: "YES"
        # Keep dev.vinny.gsd on both platforms (one App Store Connect record).
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: "NO"
        # macOS-SDK (Catalyst) build uses sandbox entitlements; iOS keeps GSD.entitlements.
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": App/GSD-Catalyst.entitlements
```

- [ ] **Step 3: Exclude the iOS-only extensions from the Catalyst build**

In `project.yml`, in the `GSD` target's `dependencies:`, add `platformFilter: iOS` to both embedded extensions:

```yaml
    dependencies:
      - package: GSDKit
        product: GSDModel
      - package: GSDKit
        product: GSDStore
      - package: GSDKit
        product: GSDSync
      - package: GSDKit
        product: GSDSnapshot
      - target: GSDWidgets
        embed: true
        platformFilter: iOS
      - target: GSDShareExtension
        embed: true
        platformFilter: iOS
```

- [ ] **Step 4: Regenerate and confirm the Catalyst destination exists**

```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -showdestinations 2>/dev/null | grep -i catalyst
```

Expected: a line like `{ platform:macOS, variant:Mac Catalyst, ... name:My Mac }`. If absent, `SUPPORTS_MACCATALYST` did not take — re-check Step 2 indentation.

- [ ] **Step 5: Confirm the iOS build still generates cleanly**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: BUILD SUCCEEDED (the iOS entitlements path is unchanged; the `[sdk=macosx*]` override does not apply to the simulator build).

> A full Catalyst build is NOT expected to pass yet — `BackgroundRefresh` (Task 2) may not compile/behave on Catalyst. Task 1 only establishes the configuration.

- [ ] **Step 6: Commit**

```bash
git add project.yml App/GSD-Catalyst.entitlements
git commit -m "build(mac): enable Mac Catalyst, exclude iOS-only extensions from the Mac build"
```

---

## Task 2: Guard background refresh out of the Catalyst build

**Files:**
- Modify: `App/Background/BackgroundRefresh.swift`

**Why:** `BGTaskScheduler` / `BGAppRefreshTask` are an iOS background-execution model that does not apply on the Mac. Guarding the bodies makes the Catalyst build the first-green build. **No behavior is lost** — the auto-archive sweep and badge refresh already run on foreground in `GSDApp.swift`'s `.task` block, and `SyncCoordinator` drives sync via its own timer/scenePhase path. The function signatures stay identical so the call sites in `GSDApp.swift` are unchanged.

- [ ] **Step 1: Wrap the registration body**

In `App/Background/BackgroundRefresh.swift`, replace the body of `register(store:)` (lines ~18-24) so the BG work is iOS-only but the signature is preserved:

```swift
    @MainActor
    static func register(store: TaskStore) {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refreshTask, store: store)
        }
        #endif
        // On Mac Catalyst there is no BGTaskScheduler: foreground refresh (GSDApp `.task`)
        // and SyncCoordinator's cadence timer cover the same freshness need.
    }
```

- [ ] **Step 2: Wrap the schedule body**

Replace the body of `schedule()` (lines ~27-31):

```swift
    static func schedule() {
        #if !targetEnvironment(macCatalyst)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
```

- [ ] **Step 3: Wrap the handler**

The `handle(_:store:)` method (lines ~33-52) references `BGAppRefreshTask`. Wrap the entire method in the same guard so the type is never referenced on Catalyst:

```swift
    #if !targetEnvironment(macCatalyst)
    @MainActor
    private static func handle(_ task: BGAppRefreshTask, store: TaskStore) {
        // ... existing body unchanged ...
    }
    #endif
```

(Keep the existing body verbatim; only the surrounding `#if … #endif` is added.)

- [ ] **Step 4: First green Catalyst build**

```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/dd build
```

Expected: BUILD SUCCEEDED. If it fails on a different file, that file needs its own guard — fix it the same way and note it in the commit.

- [ ] **Step 5: Launch smoke check**

```bash
open build/dd/Build/Products/Debug-maccatalyst/GSD.app
```

Expected: the app window opens, shows the matrix/sidebar, and tasks load (or the empty state shows). The DB resolved either to the App-Group container or the Application-Support fallback — either is fine for this check.

- [ ] **Step 6: Confirm iOS build still passes, then commit**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
git add App/Background/BackgroundRefresh.swift
git commit -m "build(mac): no-op BGTaskScheduler on Mac Catalyst (foreground refresh covers it)"
```

---

## Task 3: Fix the "Open Settings" button on Mac

**Files:**
- Modify: `App/Settings/SettingsView.swift:249-250`

**Why:** `UIApplication.openSettingsURLString` targets iOS Settings — wrong on Mac. On Catalyst, route the notification-permission prompt to the macOS System Settings Notifications pane instead.

- [ ] **Step 1: Branch the button action for Catalyst**

In `App/Settings/SettingsView.swift`, replace the existing open-settings call (lines ~249-250):

```swift
                #if targetEnvironment(macCatalyst)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    UIApplication.shared.open(url)
                }
                #else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
```

- [ ] **Step 2: Build for Catalyst**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/dd build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke**

Launch the Catalyst app, go to Settings, tap the notification "Open Settings" affordance. Expected: macOS **System Settings → Notifications** opens (not a no-op, not an error).

- [ ] **Step 4: Confirm iOS build, then commit**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
git add App/Settings/SettingsView.swift
git commit -m "fix(mac): open System Settings Notifications pane on Catalyst"
```

---

## Task 4: Verify sign-in and App-Group sharing on Mac (runtime gate)

**Files:** none changed — this task is a **provisioning + runtime verification** gate. It is the highest-risk step because these things "compile fine, fail at runtime."

**Context:** Sign in with Apple/Google here is a **web OAuth flow** via `ASWebAuthenticationSession` (`App/Auth/LiveWebAuthPresenter.swift`), not native `AuthenticationServices` — so **no `com.apple.developer.applesignin` entitlement is required** on either platform. The risks are (a) the OAuth callback anchor under Catalyst, and (b) the App-Group container actually being granted on Mac.

- [ ] **Step 1: Confirm the App-Group container resolves on Mac**

Launch the Catalyst app (signed build, see note below), then check the container exists:

```bash
ls -la ~/Library/Group\ Containers/group.dev.vinny.gsd/
```

Expected: the directory exists and contains `gsd.sqlite`. If it is **absent** and the DB instead landed in Application Support, the App-Group entitlement was not granted for Mac — register the App Group for the Mac platform in the Developer portal and re-sign (Task 7's `-allowProvisioningUpdates` + API key normally handles this; if not, enable the capability manually).

> Note: App-Group container access requires a **signed** build. If the plain `Debug` build above used an ad-hoc/dev signature without the group, do a development-signed run from Xcode (select the "My Mac (Mac Catalyst)" destination) or proceed to Task 7's signed archive first and verify there.

- [ ] **Step 2: Exercise the OAuth round-trip**

In the Catalyst app: Settings → Sign in (Google, then Apple). Expected: the `ASWebAuthenticationSession` sheet presents over the Mac window, the provider login completes, and the `gsd://` callback returns and signs you in. Watch for an `AuthError.presentationFailed` — if the anchor fails to resolve, capture the console and treat it as a follow-up bug (the `connectedScenes` anchor path in `LiveWebAuthPresenter` is expected to work on Catalyst, but this is the unknown that needs a real Mac to confirm).

- [ ] **Step 3: Confirm sync works under the sandbox**

With an account signed in, create/edit a task on Mac and confirm it pushes (the sync status chip reaches idle/success). Expected: outbound network succeeds — confirms `com.apple.security.network.client` is in effect. A hang/failure here means the sandbox network entitlement is missing from the signed build.

- [ ] **Step 4: Record findings**

No commit (no code change). Write the verified-vs-broken results into the PR description / session notes. Any failure here spawns a follow-up fix task before Task 7 ships.

---

## Task 5: Basic Mac polish — menu bar + window sizing

**Files:**
- Modify: `App/Routing/DeepLinkHandoff.swift` (add notification name)
- Create: `App/Mac/GSDMenuCommands.swift`
- Modify: `App/GSDApp.swift` (attach `.commands` on Catalyst)
- Modify: `App/ContentView.swift` (observe palette notification; gate duplicate shortcuts off on Catalyst)
- Modify: `App/Routing/QuickActions.swift` (Catalyst minimum window size)

**Why this shape:** the in-window ⌘-shortcuts already exist as hidden zero-size buttons in `ContentView` but never appear in a Mac menu bar. The menu commands reuse the **existing** `DeepLinkRoute` → `DeepLinkHandoff` → `.gsdOpenDeepLink` → `ContentView.handleDeepLink` path (the same one `QuickActions` uses) rather than duplicating navigation. To avoid double-binding the same shortcut on Mac, the duplicate hidden buttons are compiled out on Catalyst; iPhone/iPad keep them unchanged.

- [ ] **Step 1: Add the command-palette notification name**

In `App/Routing/DeepLinkHandoff.swift`, extend the existing `Notification.Name` block (after line 6):

```swift
extension Notification.Name {
    static let gsdOpenDeepLink = Notification.Name("dev.vinny.gsd.openDeepLink")
    static let gsdShowCommandPalette = Notification.Name("dev.vinny.gsd.showCommandPalette")
}
```

- [ ] **Step 2: Create the menu-command tree**

Create `App/Mac/GSDMenuCommands.swift`:

```swift
import SwiftUI
import GSDModel
import GSDSnapshot

/// Mac-only menu-bar commands. Each item drives the SAME navigation the in-window
/// ⌘-shortcuts and deep links already use (DeepLinkHandoff → .gsdOpenDeepLink →
/// ContentView), so the menu bar reuses the app's routing instead of duplicating it.
struct GSDMenuCommands: Commands {
    var body: some Commands {
        // Replace the default File ▸ New with "New Task" (⌘N).
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Task")) {
                DeepLinkHandoff.open(.capture)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        // Find ▸ open the ⌘K command palette.
        CommandGroup(after: .newItem) {
            Button(String(localized: "Find…")) {
                NotificationCenter.default.post(name: .gsdShowCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
        // Top-level "View" menu mirroring the quadrant/navigation shortcuts.
        CommandMenu(String(localized: "View")) {
            Button(String(localized: "Today’s Focus")) { DeepLinkHandoff.open(.focus) }
            Divider()
            Button(Quadrant.urgentImportant.title) { DeepLinkHandoff.open(.quadrant(.urgentImportant)) }
                .keyboardShortcut("1", modifiers: .command)
            Button(Quadrant.notUrgentImportant.title) { DeepLinkHandoff.open(.quadrant(.notUrgentImportant)) }
                .keyboardShortcut("2", modifiers: .command)
            Button(Quadrant.urgentNotImportant.title) { DeepLinkHandoff.open(.quadrant(.urgentNotImportant)) }
                .keyboardShortcut("3", modifiers: .command)
            Button(Quadrant.notUrgentNotImportant.title) { DeepLinkHandoff.open(.quadrant(.notUrgentNotImportant)) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button(String(localized: "Dashboard")) { DeepLinkHandoff.open(.dashboard) }
            Button(String(localized: "Archive")) { DeepLinkHandoff.open(.archive) }
            Button(String(localized: "Settings")) { DeepLinkHandoff.open(.settings) }
        }
    }
}
```

- [ ] **Step 3: Attach the commands on Catalyst only**

In `App/GSDApp.swift`, attach `.commands` to the `WindowGroup` scene. The scene currently ends at line ~167 (`}` closing `WindowGroup`). Apply the modifier guarded so it only affects the Mac (avoids double-binding on iPad hardware keyboards):

```swift
        WindowGroup {
            // ... existing content unchanged ...
        }
        #if targetEnvironment(macCatalyst)
        .commands { GSDMenuCommands() }
        #endif
```

- [ ] **Step 4: Observe the palette notification and gate duplicate shortcuts**

In `App/ContentView.swift`, add an observer for `.gsdShowCommandPalette` next to the existing `.gsdOpenDeepLink` observer (after line 45):

```swift
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowCommandPalette)) { _ in
                palette.showPalette = true
            }
```

Then gate the duplicate hidden buttons off on Catalyst so the menu commands are the single binding. Wrap the bodies of the buttons that the menu now owns (⌘K, ⌘F, ⌘N, ⌘1-4) — the whole `keyboardShortcuts` group (lines 78-97) becomes:

```swift
    @ViewBuilder private var keyboardShortcuts: some View {
        #if targetEnvironment(macCatalyst)
        EmptyView()   // On Mac these live in the menu bar (GSDMenuCommands) — avoid double-binding.
        #else
        Group {
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("k", modifiers: .command)
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("f", modifiers: .command)
            Button("", action: { paletteEditor = .new(.urgentImportant, prefill: nil) })
                .keyboardShortcut("n", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentImportant).url) })
                .keyboardShortcut("1", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentImportant).url) })
                .keyboardShortcut("2", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentNotImportant).url) })
                .keyboardShortcut("3", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentNotImportant).url) })
                .keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
        #endif
    }
```

- [ ] **Step 5: Set a Catalyst minimum window size**

In `App/Routing/QuickActions.swift`, in `QuickActionSceneDelegate.scene(_:willConnectTo:options:)` (lines ~45-52), add a Catalyst-only minimum size before the shortcut handling:

```swift
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        #if targetEnvironment(macCatalyst)
        if let windowScene = scene as? UIWindowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 720, height: 560)
        }
        #endif
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        _ = AppDelegate.handle(shortcutItem)
    }
```

- [ ] **Step 6: Build for Catalyst**

```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/dd build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Manual smoke**

Launch the Catalyst app. Expected:
- Menu bar shows **File → New Task (⌘N)**, a **Find… (⌘K)** item, and a **View** menu with Today's Focus / the four quadrant titles (⌘1-4) / Dashboard / Archive / Settings.
- ⌘N opens a new-task editor; ⌘K opens the command palette; ⌘1-4 focus the quadrants — each exactly once (no double-trigger).
- The window cannot be resized smaller than 720×560.

- [ ] **Step 8: Confirm iOS build (shortcuts still work there), then commit**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
git add App/Routing/DeepLinkHandoff.swift App/Mac/GSDMenuCommands.swift \
  App/GSDApp.swift App/ContentView.swift App/Routing/QuickActions.swift
git commit -m "feat(mac): menu-bar commands + minimum window size on Catalyst"
```

---

## Task 6: Mac release pipeline (archive + export, no upload yet)

**Files:**
- Create: `ExportOptions-Mac.plist`
- Modify: `scripts/release.sh`

**Why:** `scripts/release.sh` archives `generic/platform=iOS` and uploads `--type ios`. The Mac binary needs `generic/platform=macOS,variant=Mac Catalyst`, a Mac export options plist (Catalyst app-store export produces a `.pkg`), and `xcrun altool --type macos`. We add a `--mac` flag that reuses the existing bump/auth logic (DRY) and only swaps the platform-specific pieces.

- [ ] **Step 1: Create the Mac export options**

Create `ExportOptions-Mac.plist` (mirrors `ExportOptions.plist` — only the comment context differs; Catalyst app-store export emits a signed installer):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Mac Catalyst App Store / TestFlight distribution (.pkg). -->
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>52HVJ3VDSM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
```

- [ ] **Step 2: Add a `--mac` flag to the arg parser**

In `scripts/release.sh`, in the `for arg in "$@"` parse loop, add a `--mac` case that sets a platform variable. After the existing `UPLOAD=1` default near the top, add `PLATFORM="ios"`. Then in the loop:

```bash
    --mac)        PLATFORM="mac" ;;
```

- [ ] **Step 3: Select platform-specific archive/export/upload values**

After the auth-resolution block (just before the version-bump section), add:

```bash
# --- platform-specific knobs (iOS default; --mac switches to Catalyst) --------
if [[ "$PLATFORM" == "mac" ]]; then
  ARCHIVE_DEST='generic/platform=macOS,variant=Mac Catalyst'
  EXPORT_OPTIONS="$REPO_ROOT/ExportOptions-Mac.plist"
  ALTOOL_TYPE="macos"
  ARTIFACT_GLOB='*.pkg'
else
  ARCHIVE_DEST='generic/platform=iOS'
  ALTOOL_TYPE="ios"
  ARTIFACT_GLOB='*.ipa'
fi
[[ -f "$EXPORT_OPTIONS" ]] || die "export options not found at $EXPORT_OPTIONS"
```

(Remove the now-redundant `EXPORT_OPTIONS=...` and the existing `[[ -f "$EXPORT_OPTIONS" ]]` check from the top-of-file constants so this block is the single source — or leave the top default for iOS and let the `--mac` branch override it; pick one and keep it DRY.)

- [ ] **Step 4: Use the platform knobs in archive/export/upload**

Replace the hardcoded `-destination 'generic/platform=iOS'` in the archive step with `-destination "$ARCHIVE_DEST"`. Replace the `.ipa` find with `IPA="$(/usr/bin/find "$EXPORT_PATH" -maxdepth 1 -name "$ARTIFACT_GLOB" | head -1)"` and the `die` message to reference `$ARTIFACT_GLOB`. In both `xcrun altool --upload-app` invocations replace `--type ios` with `--type "$ALTOOL_TYPE"`.

- [ ] **Step 5: Dry-run the Mac build-only path**

```bash
scripts/release.sh --no-bump --mac --build-only
```

Expected: archives for Mac Catalyst, exports a `.pkg` into `build/export/`, and stops before upload with "Build-only: skipping upload." Confirm the `.pkg` exists:

```bash
ls -la build/export/*.pkg
```

> If the archive fails on signing (no Mac distribution cert/profile), that is Task 7's `-allowProvisioningUpdates` + API-key territory — note it and continue; the build-only export validates the script wiring even if signing needs the upload-path credentials.

- [ ] **Step 6: Confirm the iOS release path is unchanged, then commit**

```bash
scripts/release.sh --no-bump --build-only   # iOS path must still export an .ipa
git add scripts/release.sh ExportOptions-Mac.plist
git commit -m "build(mac): add --mac flag to release.sh for Catalyst archive/export/upload"
```

---

## Task 7: Ship the Catalyst build to TestFlight

**Files:** none (operational). Uses the existing App Store Connect API key auth already documented in `scripts/release.sh`.

**Preconditions:** `ASC_KEY_ID` / `ASC_ISSUER_ID` exported and the `.p8` in place (same as the iOS release flow). The App Group capability must be available for the Mac platform on the `dev.vinny.gsd` identifier — automatic provisioning with the API key normally enables it; if the archive's signing step reports a missing entitlement, enable the App Group for Mac in the Developer portal and retry.

- [ ] **Step 1: Bump the build number (shared version) and archive+upload Mac**

The marketing/build version is project-wide (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). Bump the build so the upload is a unique `CFBundleVersion`, then release Mac:

```bash
scripts/release.sh build --mac
```

Expected: bumps build, archives Catalyst (Release), exports the `.pkg`, uploads via `altool --type macos`, and prints the App Store Connect follow-up notes.

- [ ] **Step 2: Verify in App Store Connect**

In App Store Connect → the GSD app → TestFlight, confirm a **macOS** build appears after processing (~5-15 min). Set the export-compliance answer and assign testers (same per-build owner steps as iOS).

- [ ] **Step 3: Install from TestFlight on a Mac and smoke-test**

Install via TestFlight on an Apple Silicon Mac. Expected: launches, sign-in works, tasks sync, menu bar + window sizing behave as in Task 5/4. This is the real end-to-end gate.

- [ ] **Step 4: Commit + tag the version bump**

`scripts/release.sh` intentionally does not commit. After a successful upload:

```bash
git commit -am "chore(release): GSD $(scripts/bump-version.sh | sed -E 's/GSD //')"
git tag "v$(scripts/bump-version.sh | sed -E 's/GSD ([^ ]+).*/\1/')"
```

---

## Risks & runtime unknowns (things a code read can't settle)

These are flagged so the executor watches for them; each has a fallback:

1. **App-Group entitlement on Mac (Task 4/7).** If not granted, the DB silently uses the Application-Support fallback — app works but is isolated from any future Mac extension. Fallback: register the App Group for Mac in the portal; re-sign.
2. **OAuth presentation anchor under Catalyst (Task 4).** `LiveWebAuthPresenter`'s `connectedScenes` anchor is expected to work on Catalyst; if `presentationFailed` surfaces, it needs a Catalyst-specific anchor fix (follow-up task).
3. **`platformFilter: iOS` fully excluding the extensions (Task 1).** If the Catalyst build still tries to build/embed `GSDWidgets`/`GSDShareExtension`, fallback is to give those targets `SUPPORTS_MACCATALYST: "YES"` + a Catalyst entitlements file each (sandbox + app-group) so they ride along unverified — larger surface, so try `platformFilter` first.
4. **Mac distribution signing (Task 6/7).** Build-only export may fail without the upload-path API key; the `-allowProvisioningUpdates` + API key in the upload path is what provisions the Mac cert/profile.
5. **Keychain under the Mac sandbox (Task 4).** `KeychainTokenStore` should work for the app's own keychain in-sandbox; if token persistence fails across launches, a `keychain-access-groups` entitlement may be needed (follow-up).

---

## Self-review notes

- **Scope coverage:** project config (T1), the two real code guards — BGTask (T2) + Settings URL (T3), runtime provisioning gate (T4), the chosen "basic polish" — menu bar + window size (T5), and the TestFlight/App Store distribution path (T6 archive/export wiring, T7 upload). All three locked decisions (main-app-only, ship-to-TestFlight, include-polish) are represented.
- **Files compiled-as-is (no task needed), by design:** `Theme.swift` (UIKit appearance proxies work on Catalyst), `TaskActions.swift` (`UINotificationFeedbackGenerator` no-ops), `GSDAppIntents.swift` (`UIApplication.applicationState` valid), `QuickActions.swift` shortcut handling (inert but compiles; the file is still touched in T5 only for window sizing). These are intentionally left unchanged.
- **Symbol consistency:** `DeepLinkHandoff.open(_:)`, `DeepLinkRoute` cases, `Quadrant.title`, `.gsdOpenDeepLink`, and the new `.gsdShowCommandPalette` are all referenced consistently across T5; `GSDMenuCommands` is defined once (T5 Step 2) and attached once (T5 Step 3).
