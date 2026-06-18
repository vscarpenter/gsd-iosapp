# iPhone sync-status chip parity — design

_2026-06-18 · scope: a single UX consistency fix in the App layer._

## Problem

The `SyncStatusChip` (a quiet, hidden-when-idle toolbar indicator) is visible from any
surface on iPad — it lives in the persistent `NavigationSplitView` sidebar toolbar
(`ContentView.swift:283`). On iPhone it is built **only** by the Matrix tab
(`MatrixView.swift:74`). The Browse (`SmartViewListView`) and Dashboard (`DashboardView`)
tab toolbars carry only the `paletteButton`, so a sync that is in progress, backed up, or
errored is invisible while the user is on those tabs until they return to Matrix.

This is the lone remaining parity gap from `docs/feature-parity-iphone-ipad.md` §3b.2.

## Decision

Bring iPhone to iPad's "visible from your current surface" behavior by mirroring the same
chip onto the two iPhone content tabs that lack it (Browse + Dashboard). The chip renders
nothing when idle/healthy/nothing-pending (`SyncStatusChip.swift:16-18`), so this adds no
persistent chrome — only lets the already-ephemeral indicator be seen from any content tab.

Considered and rejected: a Settings-tab badge (can't show the live spinner, changes the
indicator's semantics) and doing both (over-engineered for a minor nit — YAGNI).

The iPhone **Settings** tab is intentionally left without the chip: it already shows the
full sync section, and it is the chip's tap destination.

## Design

### Shared toolbar helper

Extract a free `@ToolbarContentBuilder` helper alongside the existing `paletteButton` /
`showCompletedToggle` helpers in `MatrixView.swift` (already the home for shared compact
toolbar helpers — `SmartViewListView` reuses `paletteButton` from there):

```swift
@MainActor @ToolbarContentBuilder
func syncStatusChip(_ sync: SyncCoordinator, _ palette: PaletteController) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                       health: sync.health) { palette.compactTab = 3 }   // → Settings tab
    }
}
```

`MatrixListContent` is repointed at this helper so the compact chip has one definition.

### The asymmetry trap (the reason Browse ≠ Dashboard)

- `SmartViewListView` (Browse) is **iPhone-only** — iPad uses sidebar rows, never this view.
  Safe to add the chip unconditionally.
- `DashboardView` is **shared** — it is both the iPhone Dashboard tab and the iPad split-view
  detail (`ContentView.swift:299`). Adding the chip unconditionally would render **two** chips
  on iPad (sidebar + detail toolbar), and the `compactTab = 3` tap is meaningless there. So the
  Dashboard chip is **gated to compact** via `if sizeClass == .compact`, which
  `@ToolbarContentBuilder` supports natively.

## Changes (4 edits)

1. `MatrixView.swift` — add `syncStatusChip(_:_:)`; repoint `MatrixListContent`'s toolbar at it.
2. `SmartViewListView.swift` — inject `@Environment(SyncCoordinator.self)`; add
   `syncStatusChip(sync, palette)` to the toolbar (unconditional; iPhone-only view).
3. `DashboardView.swift` — inject `SyncCoordinator` + `@Environment(\.horizontalSizeClass)`;
   add the chip **gated to `.compact`**.
4. No iPad change (sidebar chip unchanged); no iPhone Settings-tab change.

## Verification

Clean `xcodebuild` on both simulators:
- iPhone 17 Pro — chip appears on Matrix, Browse, and Dashboard when sync is active/pending/errored.
- iPad Pro 13-inch — Dashboard detail shows **no** toolbar chip; the single chip stays in the sidebar.

App-layer glue has no unit-test target; build + the above smoke is the gate (per CLAUDE.md).

## Out of scope

The `paletteButton` / `showCompletedToggle` / `syncStatusChip` helpers living in `MatrixView.swift`
is a pre-existing locality quirk; relocating them to a dedicated `ToolbarHelpers.swift` is an
unrelated refactor and is not part of this change.
