# Mac Catalyst Share Extension

**Date:** 2026-06-24
**Status:** Approved — ready for implementation

## Problem

On iPhone/iPad, GSD appears in the system Share sheet (web URLs + selected
text) via an embedded Share Extension. On the Mac Catalyst build, GSD is **not**
a share target — it does not appear in the macOS Share menu.

## Root cause

This was a deliberate scope deferral, not a technical blocker. The Mac Catalyst
port (`docs/superpowers/plans/2026-06-15-mac-catalyst.md`) was explicitly
"main app only" and listed "Share Extension on Mac" as out of scope. To keep
that scope, commit `3ac399b` added `platformFilter: iOS` to the
`GSDShareExtension` embed dependency, because the iOS-only `.appex` would
otherwise fail to build/embed under Catalyst.

The extension was never made Catalyst-buildable. Enabling it now is a
"de-defer": make the target build for Mac Catalyst and re-include it in the
Catalyst app bundle.

## Why this is low-risk

- `GSDModel` and `GSDSnapshot` — the extension's only dependencies — already
  compile for macOS (the Catalyst app ships with them).
- `ShareViewController` is plain UIKit hosting SwiftUI, which Catalyst runs
  natively. No code change needed.
- The cross-process handoff uses the App Group `group.dev.vinny.gsd`, which the
  Catalyst **app** already reads and writes successfully (shipped in 1.8.2). The
  Catalyst extension writes to the same outbox the Mac app already drains.

## Decisions (from brainstorming)

1. **Approach:** Enable the existing Share Extension for Mac Catalyst (reuse all
   code). Rejected: a separate native AppKit extension (duplicates UI, awkward to
   embed in a Catalyst app, far more work) and macOS Services / "Open with"
   (not the Share menu the request asked for).
2. **Content types:** Parity with iOS — one web URL or selected text. Reuse the
   existing `NSExtensionActivationRule`; no new extraction logic.
3. **Verification split:** Implementer build-verifies that a Catalyst build
   embeds the `.appex`; the owner confirms the Share-menu appearance on a real
   Mac (install to /Applications, possibly enable in System Settings).
4. **Widgets stay out of scope** — they remain iOS-only.

## Architecture & data flow (unchanged)

```
macOS Share menu (Safari, etc.)
   → GSDShareExtension.appex            [now built for Catalyst, embedded in the Mac app]
   → ShareViewController extracts URL/text
   → ShareComposeView (title · quadrant · tags)
   → ShareOutboxStore.write(SharedCapture) → App Group group.dev.vinny.gsd
   → Mac GSD app drains via ShareInbox  [already works on Catalyst]
```

No code changes to the extension or the data path. A URL shared on Mac flows
through the same `URLSanitizer` and surfaces as the tappable editor link.

## Components / changes

### 1. `project.yml` — `GSDShareExtension` target gains Catalyst support

Mirrors the `GSD` app target's Catalyst settings:

- `SUPPORTS_MACCATALYST: "YES"`
- `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: "NO"` (keep
  `dev.vinny.gsd.share` on both platforms — one App Store Connect record)
- `"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": ShareExtension/GSDShareExtension-Catalyst.entitlements`

The target keeps `platform: iOS` — Mac Catalyst is the iOS app built against the
macOS SDK, exactly as the app target is configured.

### 2. `project.yml` — `GSD` app dependency

Remove `platformFilter: iOS` from the `GSDShareExtension` embed so it bundles on
iOS **and** Catalyst. **Keep** `platformFilter: iOS` on `GSDWidgets`.

### 3. New `ShareExtension/GSDShareExtension-Catalyst.entitlements`

Minimal macOS App-Sandbox + the App Group:

- `com.apple.security.app-sandbox = true`
- `com.apple.security.application-groups = [group.dev.vinny.gsd]`

No network or file entitlements — the extension only writes a `SharedCapture` to
the App-Group outbox; the app performs all syncing. The iOS
`ShareExtension/GSDShareExtension.entitlements` is left untouched (app-group
only). A separate Catalyst file is required because macOS sandbox keys are not
valid iOS entitlements; the `[sdk=macosx*]` override applies them only to the
Catalyst build — the same pattern the app target uses with
`App/GSD-Catalyst.entitlements`.

## Error handling / caveats

- **Runtime registration (owner-verified):** macOS surfaces the extension only
  after the app is registered with Launch Services (run from /Applications), and
  the user may need to enable it under System Settings → Login Items &
  Extensions → Sharing. This is inherent macOS behavior, not a defect.
- **Version & signing:** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` and
  `DEVELOPMENT_TEAM` are project-wide, so the Catalyst `.appex` stays in
  lock-step and signs with the same team automatically.

## Verification

- `xcodegen generate`.
- **iOS build** for iPhone (`iPhone 17 Pro`) and iPad (`iPad Pro 13-inch (M5)`)
  — confirm the iOS embed still works (no regression).
- **Mac Catalyst build:**
  `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=macOS,variant=Mac Catalyst' build`,
  then confirm `GSDShareExtension.appex` is present inside the built
  `GSD.app/Contents/PlugIns/` — proof it embedded under Catalyst.
- **Owner (real Mac):** install to /Applications, confirm GSD in the Share menu,
  share a URL, confirm it becomes a task with the tappable link.

## Files

- EDIT `project.yml`
- NEW `ShareExtension/GSDShareExtension-Catalyst.entitlements`
- Regenerated artifacts: `GSD.xcodeproj`, `App/Info.plist`

## Out of scope

- Widgets on Mac.
- Broadening accepted content types beyond the iOS parity (URL + text).
- The actual release/ship (`scripts/release.sh --mac`).
