# iPad Swipe Parity — Design

**Date:** 2026-06-05
**Goal:** Give iPad matrix cards the same swipe-to-reveal actions the iPhone has, without losing the iPad's existing drag-to-move and long-press menu.

## Background

iPhone uses a `List`, so `TaskListRow` gets native `.swipeActions` for free. iPad uses a `LazyVGrid` of cards (`MatrixGridView` → `QuadrantCell`), and `.swipeActions` is **`List`-only** — it silently no-ops outside a `List`. That's the whole bug: it was never a forgotten modifier, it's a structural difference. iPad instead got `.draggable` (drag-to-move) + `.contextMenu`.

A throwaway spike (`SwipeSpikeRow`) was built to answer the one load-bearing risk: **can a custom horizontal swipe coexist with `.draggable`, `.contextMenu`, and tap-to-edit on iOS 26?** Confirmed on a physical iPad:

| Gesture | Result |
|---|---|
| Drag-to-move | ✅ works |
| Long-press menu | ✅ works |
| Swipe (card slides) | ✅ works |
| Tapping the revealed buttons | ❌ → **fixed** (see below) |

The reveal buttons sat *behind* the sliding card; the card's tap-to-close / offset hit-region / `.draggable` interaction ate the tap. **Fix (proven on device): layer the reveal buttons *in front of* the card while open.** Risk is fully retired; remainder is execution.

## Decisions (owner-approved)

### Component — promote the spike to `SwipeRevealRow`
- Extract the spike into a real component (own file `App/Matrix/SwipeRevealRow.swift`), generic over its card content + menu, reused by `QuadrantCell`.
- Reveal buttons layered **in front** of the card (only while open); card stays opaque (`Surface.surface`) so actions hide when closed.
- **Directional lock:** the swipe `DragGesture` only claims horizontal-dominant drags (`abs(width) > abs(height)`), so vertical pans reach the parent `ScrollView` and short taps still reach tap-to-edit.
- Coexists with the card's existing `.draggable(task.id)`, `.contextMenu`, and `.onTapGesture` — all preserved.

### Leading edge (swipe right) — Complete, with full-swipe
- Toggles completion; label/icon flips **Complete ↔ Uncomplete** with `task.completed` (parity with iPhone's `TaskListRow`). Color `Surface.success` (green).
- **Full-swipe to commit:** a long right-swipe past the full-swipe threshold completes immediately on release (no tap); a short swipe snaps open to a tappable button.

### Trailing edge (swipe left) — Snooze + Delete
- Two buttons matching iPhone exactly: **Snooze** (`QuadrantStyle.accent(.notUrgentNotImportant)`, slate, 1-hour preset) + **Delete** (`Surface.alert`, rust, destructive).
- **No full-swipe on the trailing edge** — Delete always requires a deliberate tap. Deliberate deviation from iPhone's default full-swipe-delete to avoid accidental destruction from an over-swipe.

### Auto-close other open rows
- Only one row open at a time within a `QuadrantCell`: cell holds `@State openTaskID: String?`, passed to each row; a row snaps closed when it's no longer the open one (matches iPhone `List` behavior). Per-cell scope is sufficient (cross-quadrant double-opens are rare).

### Accessibility — already covered
- VoiceOver users never swipe; the cell already exposes `.accessibilityActions` (Complete/Edit/Delete/Snooze/timer). Keep them. Reveal buttons keep their `.accessibilityLabel`.

## Out of scope (YAGNI)
- Full-swipe-to-delete on the trailing edge (intentionally omitted; see above).
- Snooze-preset submenu on swipe (1-hour quick preset only; full presets stay in the long-press menu + editor).
- Cross-quadrant "only one open in the entire matrix" coordination (per-cell is enough).
- Touching the iPhone path — `TaskListRow` / native `.swipeActions` are unchanged.
- The `B/C/o` debug counters from the spike — stripped.

## Verification
- `swift test` (GSDKit) stays green — no logic-layer change.
- `xcodebuild` builds clean for the `GSD` scheme on both iPhone 17 Pro and iPad Pro 13-inch (M5) simulators.
- Physical iPad: swipe right → Complete fires (tap) and full-swipe completes; swipe left → Snooze + Delete both fire; opening one row closes another; drag-to-move and long-press menu still work; vertical scroll unaffected.
- `.claude/decisions/` updated: new log for `SwipeRevealRow.swift`, appended rationale on `QuadrantCell.swift`.
