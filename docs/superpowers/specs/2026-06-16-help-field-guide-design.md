# Help "Field Guide" — iOS / iPad / Mac

**Date:** 2026-06-16
**Status:** Approved
**Authority:** This spec; product language in `PRODUCT.md`; behavior in `spec.md`.

## Purpose

The web app (gsd.vinny.dev) has a "Field Guide" help drawer that explains the
matrix, the capture bar, the four quadrants, the quick-add syntax, keyboard
shortcuts, gestures, optional cloud sync, and privacy. The native apps have no
equivalent — new users rely on first-run onboarding only, which is skippable and
not re-readable in context. This adds a parity Help surface to iPhone, iPad, and
Mac so help is available across all three versions of GSD.

## Design

One shared, **static** SwiftUI sheet — `HelpView` — rendered in GSD's editorial
language (paper background, New York serif titles, ink/tint tokens, pigment
dots). It reads **no `@Observable` stores** (pure content), so — like `AboutView`
— it needs no Catalyst environment re-injection. It rides the exact presentation
rails the About panel already uses: a `.gsdShowHelp` notification → a `.sheet`
owned by `ContentView`.

### Entry points

- **Settings ▸ About** — a "How to use GSD" row (`questionmark.circle` label)
  beside "Show Onboarding Again". Tapping posts `.gsdShowHelp`. iPhone, iPad, Mac.
- **Mac Help menu** — a new `CommandGroup(replacing: .help)` in `GSDMenuCommands`
  with a "GSD Help" item bound to `⌘?`, posting `.gsdShowHelp`. Replaces the empty
  stock Help menu (an App-Store-polish win; the app currently ships none).

Both routes converge on the same notification and the single sheet host in
`ContentView`, mirroring how `.gsdShowAbout` already works.

### Content sections (full mirror, adapted)

1. **Header** — "FIELD GUIDE" eyebrow + "How to use GSD" serif title, with a close
   `xmark` bound to `.cancelAction` (Esc), cloned from `AboutView`'s overlay.
2. **One board, one capture bar** — *The matrix* and *The capture bar*, two
   labeled paragraphs with the web's left accent rule.
3. **The four quadrants** — four rows (pigment dot + serif name + one-line
   description), data-driven from `Quadrant.allCases` + `QuadrantStyle.accent`.
4. **Quick-add smart syntax** — token legend (`!`, `!!`, `*`, `#tag`) + the worked
   example sentence, styled with the existing monospace-token idiom.
5. **Keyboard shortcuts** — **Mac/iPad only** (hidden on iPhone). The native set,
   *not* the web's bare keys: `⌘K` palette · `⌘F` search · `⌘N` new task · `⌘1–4`
   quadrants · `⌘?` this guide · `Esc` close, plus the "suppressed while typing in
   a field" note.
6. **Editing, completing & drag-drop** — shown on **all** platforms (this is
   iPhone's interaction story): tap the checkbox to complete (recurring tasks
   spawn the next instance), tap a card to edit, drag onto another quadrant to
   reclassify (8-pt activation distance, so plain taps still open the editor).
7. **Cloud sync (optional)** — adapted to native: sync is managed in **Settings**;
   a blue badge means pending changes to push, a red badge means re-authenticate.
   No "cloud icon in the top bar" (that is web chrome).
8. **Privacy** — local-first; nothing leaves the device unless you sign in; reuses
   the onboarding privacy wording; points to Settings.
9. **Footer** — "Read the About page →" link to `gsdtaskmanager.com`.

All copy via `String(localized:)`, consistent with the rest of the app.

### Platform gating for §5

Show the keyboard-shortcuts section where a hardware keyboard is realistic:

```swift
#if targetEnvironment(macCatalyst)
true
#else
UIDevice.current.userInterfaceIdiom == .pad
#endif
```

Mac always; iPad yes; iPhone no.

## Files

**New** — `App/Help/HelpView.swift`: the sheet plus small private subviews
(`HelpSection`, `QuadrantGuideRow`, `SyntaxRow`, `ShortcutRow`). No store reads.

**Modified (4, all minimal):**

- `App/Routing/DeepLinkHandoff.swift` — add `static let gsdShowHelp`
  (`"dev.vinny.gsd.showHelp"`) to the `Notification.Name` extension.
- `App/ContentView.swift` — add `@State showHelp`, a `.sheet(isPresented:)`
  presenting `HelpView()`, and `.onReceive(.gsdShowHelp)`. Direct clones of the
  existing About lines (44, 56).
- `App/Settings/SettingsView.swift` — add the "How to use GSD" row in
  `aboutSection`, posting `.gsdShowHelp`.
- `App/Mac/GSDMenuCommands.swift` — add `CommandGroup(replacing: .help)` with the
  "GSD Help" button (`⌘?`).

## Reuse vs. new

Reuse: `AppMark`, design tokens (`Surface`, `QuadrantStyle`, `Radius`, `.serif`),
the monospace-token styling idiom, and the `AboutView` sheet/close pattern. Build
fresh: the quadrant-guide rows and the syntax/shortcut rows — the web's list
layouts differ from onboarding's diagram layouts, so Help stays decoupled from
`OnboardingView` rather than over-coupling to its private structs.

## Verification

- `cd GSDKit && swift test` — unchanged (no GSDKit logic touched; content is
  app-layer).
- `xcodegen generate`, then build for **iPhone** and **iPad** simulators and a
  **Mac Catalyst** build.
- Smoke: open Help from Settings on iPhone, iPad, and Mac, and from the Mac Help
  menu / `⌘?`. Confirm the shortcuts section is **absent on iPhone** and **present
  on iPad/Mac**, and the close button / Esc dismisses it.

## Deployment

New user-facing feature → **minor** bump to `1.8.0 (19)`. Build numbers stay
aligned across platforms (bump once, build both `--no-bump`):

1. `scripts/release.sh minor` — bump to 1.8.0 (19), archive iOS, upload to TestFlight.
2. `scripts/release.sh --mac --no-bump` — Mac Catalyst at 1.8.0 (19), upload.
3. Commit the version bump + tag `v1.8.0`, push.

Post-upload (owner, in App Store Connect): per-build export-compliance answer +
assign testers, for both the iOS and macOS builds.

## Out of scope (YAGNI)

- No command-palette or toolbar `?` entry point (Settings row + Mac Help menu only).
- No searchable/indexed help, no remote/markdown-loaded content — static SwiftUI.
- No in-context tooltips or coach marks; this is a single reference sheet.
