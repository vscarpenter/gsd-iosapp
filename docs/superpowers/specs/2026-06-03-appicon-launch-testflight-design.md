# App Icon · Launch Screen · TestFlight Polish — Design

**Date:** 2026-06-03
**Goal:** Make the app TestFlight-ready: add the missing app icon, a branded launch screen, a privacy manifest, and the export-compliance flag.

## Decisions (owner-approved)

### App icon — "Quadrant + Checkmark" (V1, solid)
- The Eisenhower 2×2 matrix in the brand quadrant colors, with one bold white checkmark spanning the center ("get stuff **done**").
- **Brightened/vibrant palette** anchored on the app's quadrant hues (value boosted ~1.4×, gray lightened) so it pops on the Home Screen:
  - Q1 Do First (top-left): `#FD4836` (red)
  - Q2 Schedule (top-right): `#3699CB` (sky blue)
  - Q3 Delegate (bottom-left): `#C49823` (gold)
  - Q4 Eliminate (bottom-right): `#A0A0A0` (light gray)
- White check, stroke 92 / round caps, soft drop shadow for legibility over the lighter olive/gray.
- **Format:** single universal `1024×1024` PNG, **opaque (no alpha)** — App Store requirement; iOS applies the squircle mask on device.
- Editable source committed at `Design/icon/app-icon.svg` (regenerate steps in `Design/icon/README.md`); asset at `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.

### Launch screen — minimal branded
- The icon's quadrant+check mark, rounded (squircle), centered (~120pt) on an **adaptive background**:
  - Light: `#FAFAF8` (near-white)
  - Dark: `#17171A` (charcoal)
- No text (launch screens can't localize or be dynamic — Apple HIG).
- Implemented via `UILaunchScreen` Info.plist keys (`UIImageName` + `UIColorName`) referencing asset-catalog entries — **no storyboard**.
- Assets: `LaunchMark.imageset` (@1x/2x/3x) + `LaunchBackground.colorset` in `App/Assets.xcassets`.

### Privacy manifest — `PrivacyInfo.xcprivacy`
- Added to the app **and** both extensions (`App/`, `Widgets/`, `ShareExtension/`) so all bundled binaries are clean for App Store review.
- `NSPrivacyTracking = false`, no tracking domains, no collected data types (tasks sync to the user's own backend, not developer analytics).
- Required-reason APIs declared:
  - `NSPrivacyAccessedAPICategoryUserDefaults` → `1C8F.1` (App-Group shared UserDefaults, `group.dev.vinny.gsd`).
  - `NSPrivacyAccessedAPICategoryFileTimestamp` → `C617.1` (timestamps of files in the app/app-group container; SQLite/GRDB + file IO).

### Export compliance
- `ITSAppUsesNonExemptEncryption = false` in the app Info.plist (app uses only standard HTTPS — exempt) so App Store Connect stops asking on every upload.

## Out of scope (YAGNI)
- iOS 18 dark/tinted icon variants (single standard icon is sufficient for TestFlight).
- App Privacy "nutrition label" answers (filled in App Store Connect, not the manifest).
- Marketing version bump (0.1.0 / build 1 is fine for first TestFlight).

## Verification
- `xcodegen generate` + `xcodebuild` build succeeds for the `GSD` scheme (app + both extensions).
- simctl: install + launch shows the icon on the Home Screen and the branded launch screen; `PrivacyInfo.xcprivacy` present in the built `.app`.
