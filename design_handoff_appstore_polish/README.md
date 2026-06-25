# Handoff: App Store Pre-Submission Polish (GSD)

## Overview

This package is the remediation list from a pre-submission design review of the GSD iOS/Mac app. It is **not** a "build a new UI" handoff — it's a set of small, scoped fixes to the **existing SwiftUI codebase** to close out design polish before App Store submission. Each item below names the exact file, the current code, the change, and acceptance criteria.

The full visual review is included as a reference: `GSD Design Review.dc.html` (open in a browser). It carries the rationale and the measured contrast data behind these tasks.

## About the design files

The single HTML file in this bundle (`GSD Design Review.dc.html`) is a **design-review document**, not production code. Do not port it into the app. It exists to explain *why* each task below matters and to show the target color/sizing values. All real work happens in the existing Swift files named in each task.

## Status of the original review

The review raised 7 findings. **F1 (manual accessibility pass — VoiceOver / Dynamic Type AX / Reduce Motion) has already been completed and verified on-device by the app owner.** This handoff covers the remaining six: F2–F7.

## Codebase context

- SwiftUI app. Design tokens live in `App/Theme/Theme.swift` (`Surface.*`, `Radius.*`) and `App/Theme/QuadrantStyle.swift` (`QuadrantStyle.accent/wash/symbol`).
- **Hard rule from the design system:** color is rationed. The only strong color is the four quadrant accents; everything structural is the `Surface` neutral ramp. Every color is light/dark adaptive via `Color(light:dark:)`. **Never introduce a raw SwiftUI system color** (`.orange`, `.blue`, `.red`, …) into UI — use a `Surface.*` or `QuadrantStyle.*` token.
- Continuous corners everywhere (`style: .continuous`), one soft warm shadow, 44pt minimum hit targets.
- Follow the repo's own `coding-standards.md`: these are **Trivial / Standard tier** tasks. No spec needed for the trivial ones; lightweight `tasks/todo.md` entry for the Standard ones. Match existing code style exactly.

---

## Tasks

### F2 — Replace off-palette `.orange` in the sync status chip  ·  Tier: Trivial  ·  Priority: HIGH

**File:** `App/Sync/SyncStatusChip.swift` (lines ~38 and ~41)

**Current:**
```swift
case .error:
    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
case .idle:
    if health.level == .warning {
        Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
    }
```

**Problem:** `.orange` is the only color in the entire app drawn outside the rationed palette, and it is **not** light/dark adaptive — it won't sit correctly on the warm-paper ink ramp in dark mode.

**Change:**
- The genuine **error** case (`.error`) → `Surface.alert` (the app's destructive/error pigment).
- The softer **warning** case (`health.level == .warning`) → distinguish it from a hard error. Use `QuadrantStyle.accent(.urgentNotImportant)` (ochre — the app's existing "attention, not alarm" pigment). If a quadrant pigment feels too loud for chrome here, fall back to `Surface.ink3`. Pick one and apply consistently; prefer ochre to keep error vs. warning visually distinct.
- Update the doc comment at the top of the file: it currently says "amber warning glyph" — replace "amber"/"orange" wording so the comment matches the palette tokens now used.

**Acceptance criteria:**
- No `.orange` (or any raw system color) remains in this file.
- Error and warning render in two visually distinct, palette-derived colors.
- Both render correctly in light **and** dark mode (verify the dark-mode glyph against the paper-dark background).

---

### F3 — Close the standing quadrant-contrast note  ·  Tier: Trivial  ·  Priority: LOW (decision, ~0 code)

**File:** `App/Theme/QuadrantStyle.swift`

**Context:** The file carries a standing note (referenced in `PRODUCT.md`) to "re-verify these accent pairs" for contrast. This has now been measured. As **text on their actual surfaces, all four accents pass WCAG AA (≥4.5:1)** in light mode:

| Accent (light) | On white card | Ratio | AA |
|---|---|---|---|
| Tide · Schedule | `#FFFFFF` | 6.3:1 | pass |
| Rust · Do First | `#FFFFFF` | 5.9:1 | pass |
| Slate · Eliminate | `#FFFFFF` | 5.5:1 | pass |
| Ochre · Delegate | `#FFFFFF` | 5.0:1 | pass (tightest) |
| Tag chips (footnote) | accent wash | ~4.8:1 | pass (borderline) |

None reach AAA (7:1), so the "AAA where feasible" aspiration is not met by the colored text — this is an accepted trade for the rationed palette. As **large** text (the `serif(.title3)` quadrant headings) every accent clears even AAA-large.

**Change:** Update the standing comment in `QuadrantStyle.swift` (and the related note in `PRODUCT.md`) from "re-verify" to "verified: all pairs pass AA as text; AAA-large for headings; tag chips ~4.8:1 (AA)". **No color change is required to ship.**

**Optional (only if you want AAA headroom on small colored text):** the tightest case is the `#tag` chip (footnote) on its wash (~4.8:1). To gain margin, darken **ochre** light value `0x8A6A22` by ~6% and deepen the four `wash(_:)` light values a touch. Re-measure after any change. Do **not** do this unless explicitly requested — AA is the firm floor and is met.

**Acceptance criteria:**
- The "re-verify" note is replaced with the verified result.
- If (and only if) asked to chase AAA: ochre + washes adjusted and all pairs re-measured ≥4.5:1, with the heading pairs still ≥7:1.

---

### F4 — Restyle the tag-remove control in the task editor  ·  Tier: Standard  ·  Priority: MEDIUM

**File:** `App/Editor/TaskEditorView.swift` (the `tagField` computed property)

**Current:**
```swift
ForEach(tags, id: \.self) { tag in
    Button { tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
        .buttonStyle(.bordered)
}
```

**Problems:**
1. The "✕" is an inline glyph glued to the label — a tiny, sub-44pt tap target.
2. `.buttonStyle(.bordered)` is the one chip in the app that ignores the established **capsule + quadrant-wash** chip vocabulary used in `CaptureBar.swift` and `TaskCardView.swift` (`tagRow`).

**Reference — the canonical chip style** (from `TaskCardView.tagRow`):
```swift
Text("#\(tag)")
    .font(.footnote)
    .foregroundStyle(QuadrantStyle.accent(task.quadrant))
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(QuadrantStyle.wash(task.quadrant), in: Capsule())
```

**Change:** Render each editor tag as a wash capsule matching the reference, but **editable**: add a distinct trailing remove control (an `xmark` / `xmark.circle.fill` SF Symbol) inside the capsule, with the tap area sized to a proper hit target (the row already supplies ~44pt height; ensure the remove control's `contentShape`/frame is comfortably tappable, not a 10pt glyph). Use the **editor's selected `quadrant`** for the accent + wash (the editor has `@State quadrant` in scope), so the tags recolor with the chosen quadrant — consistent with how the rest of the app tints tags by quadrant.

Keep the existing add-tag `TextField` + `Add` button below unchanged.

**Acceptance criteria:**
- Editor tags use the capsule + wash style, tinted by the editor's current `quadrant`.
- The remove control is a clearly separate, comfortably-tappable target (not an inline text glyph).
- VoiceOver: the remove control has an `accessibilityLabel` like "Remove tag <name>".
- Adding/removing tags still respects `FieldLimits.maxTags`.

---

### F5 — Make the card overflow "⋯" scale with Dynamic Type  ·  Tier: Trivial  ·  Priority: MEDIUM

**File:** `App/Matrix/TaskCardView.swift` (the `trailingControls` property, ~line 81)

**Current:**
```swift
Image(systemName: "ellipsis")
    .font(.system(size: 17, weight: .semibold))
    .foregroundStyle(Surface.ink3)
    .frame(width: 30, height: 30)
```

**Problem:** The fixed `size: 17` keeps the overflow glyph the same size while the surrounding `.headline` title grows at AX text settings — it's the one **interactive** control in the trailing cluster that doesn't scale.

**Change:** Use a Dynamic-Type-relative size. Replace `.font(.system(size: 17, weight: .semibold))` with a text-style base, e.g. `.font(.title3.weight(.semibold))` (or `.imageScale(.large)` on a text-style font). Keep `Surface.ink3` and the existing hit-target frame; let the glyph frame grow naturally (avoid hard-pinning width/height so small it clips at AX sizes — verify it doesn't).

Leave the **decorative** fixed-size glyphs as-is (completion checkmark at size 13 in `completionDisc`, onboarding lock/check) — those are non-interactive and fine.

**Acceptance criteria:**
- The "⋯" grows with Dynamic Type alongside the card title.
- Hit target stays ≥44pt (the row height supplies it); glyph is not clipped at the largest AX size.
- No visual regression at the default text size.

---

### F6 — Tighten the app icon margins  ·  Tier: Trivial (asset)  ·  Priority: LOW / OPTIONAL

**Files:** `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png` and `AppIcon-Dark.png` (1024×1024 each)

**Context:** The icon is correct and on-brand (the 2×2 quadrant mark echoing `OnboardingView.AppMark`, with light + dark variants wired in `Contents.json`). The four tiles sit inside generous margins, so the mark fills a smallish fraction of the rounded square and reads slightly small at home-screen / Spotlight sizes.

**Change (optional):** Regenerate both 1024² PNGs with the tile grid scaled up ~12–18% (less outer padding). Keep the subtle drop shadow under the Do-First checkmark. **Source of truth for the geometry is `AppMark`** in `OnboardingView.swift` (gap = 7% of width, tiles fill the rest) — adjust the canvas padding around that same mark rather than redrawing tiles.

**Acceptance criteria:**
- Both light and dark 1024² variants updated and still valid App Store icons (no alpha, no pre-baked corner radius — the system masks).
- At small sizes, the slate (bottom-right) tile still separates clearly from the dark variant's near-black field.
- This is optional — skip if not regenerating assets this cycle.

---

### F7 — Verify the hand-built "Sign in with Apple" button against current HIG  ·  Tier: Standard (verification)  ·  Priority: LOW / OPTIONAL

**Files:** `App/Settings/SettingsView.swift` (account section) and `App/Onboarding/OnboardingView.swift` (`syncSignInButtons`) — both hand-render the same button.

**Context:** The button is hand-rendered (black-on-light / white-on-dark, `applelogo` symbol, 8pt corner, 44pt min height) to drive the web-redirect OAuth flow rather than the native `SignInWithAppleButton` (intentional, per the inline comment, to satisfy Guideline 4.8). Because it's bespoke, it's the one auth control a reviewer may compare against Apple's button spec.

**Change:** No functional change expected. Verify (and adjust only if off-spec) against Apple's "Sign in with Apple" button guidance:
- Exact label wording: "Sign in with Apple".
- Logo size and the logo-to-text margin lockup.
- Corner radius and minimum height within Apple's allowed range.
- Both light and dark appearances render the correct contrast (black button on light, white on dark).

Keep the two implementations (Settings + Onboarding) **identical** — if you adjust one, mirror it. Consider extracting a single shared `AppleSignInButton` view if they drift (Standard-tier refactor, only if it reduces duplication).

**Acceptance criteria:**
- Button matches Apple's current button spec in both appearances, or a noted, justified deviation.
- Settings and Onboarding renditions are pixel-identical.

---

## Suggested order

1. **F2** — quick, palette-correctness win (Trivial, HIGH).
2. **F5** — quick Dynamic Type fix (Trivial, MEDIUM).
3. **F4** — the one Standard-tier UI change; touches a screen users live in (MEDIUM).
4. **F3** — documentation/decision, no code unless chasing AAA (LOW).
5. **F6 / F7** — optional; do if regenerating assets / before a review-sensitive submit.

None of these block a build. F2 is the only one that meaningfully affects the shipped visual palette.

## Files in this bundle

- `README.md` — this document (self-sufficient; a developer not in the original review can work from it alone).
- `GSD Design Review.dc.html` — the full visual review with rationale and measured contrast data. Reference only; do not ship.
