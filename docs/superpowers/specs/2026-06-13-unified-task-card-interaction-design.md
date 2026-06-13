# Unified Task-Card Interaction (web ↔ iOS parity)

- **Date:** 2026-06-13
- **Status:** Draft (awaiting review)
- **Authors:** Vinny Carpenter + Claude
- **Scope:** iOS app only (`App/`). No web-app changes; no model/store/sync changes.

## 1. Problem

A user fluent in the GSD **web app** has to relearn the primary task interaction on **iOS**, because the two surfaces wire the same-looking control to different actions.

On the web task card:
- A **circle at the trailing edge** marks the task complete.
- Hovering reveals an inline **Share / Edit / Delete** icon row.
- Clicking the **card body does nothing**.

On the iOS card today ([`App/Matrix/TaskCardView.swift`](../../../App/Matrix/TaskCardView.swift)):
- `completionDisc` (lines 65–78) renders a 28pt circle that is **visually identical** to the web's complete control — empty ring when active, filled with a checkmark when done.
- But the disc carries **no gesture** and is `.accessibilityHidden(true)`. The only tap handler on the row is the card-body `TapGesture { onEdit }` in [`App/Matrix/TaskListRow.swift`](../../../App/Matrix/TaskListRow.swift) (line 33).
- So tapping the circle — the web user's muscle-memory action for "complete" — **opens the editor instead.** The disc is decorative; it looks actionable but is not.
- Secondary actions (Edit/Share/Delete/Move/Snooze/Duplicate/Timer) live only in **swipe actions** and the **long-press context menu** — discoverable to iOS power users, invisible to someone arriving from the web.

This is both a **cross-platform consistency gap** and a **latent usability bug**: an actionable-looking control that performs the wrong action.

Note: the root product spec already mandates the missing behavior — [`spec.md:337`](../../../spec.md) lists completion "via leading swipe, **checkbox tap**, or context menu." The swipe and context-menu paths shipped; the **checkbox tap did not.** This work completes the spec rather than diverging from it.

## 2. Goals

- A web-fluent user completes a task on iOS the same way they do on web (**tap the circle**) — no relearning of the primary action.
- Edit / Share / Delete are **discoverable** on iOS without knowing the hidden swipe/long-press gestures.
- Stay native: do not clutter the phone card with an always-visible icon row or fight iOS conventions.
- One change point covers **both iPhone and iPad**, which are co-equal targets.

## 3. Non-goals

- No changes to the web app.
- No changes to `TaskActions`, `TaskStore`, the model, or sync.
- No change to the editorial visual language (spine, serif headers, palette, disc styling).
- No removal of existing swipe actions, the long-press context menu, or drag-to-move — they remain as accelerators.
- Editor / detail screen redesign is out of scope.

## 4. The unified interaction contract

The principle is **identical mental model, idiomatic execution** — unify the *primary* action and the *meaning of a card tap*; surface *secondary* actions through each platform's idiom.

| Action | Web | iOS (proposed) |
|---|---|---|
| **Complete / uncomplete** | tap trailing circle | **tap trailing disc** (NEW) |
| **Open / edit** | click pencil (body inert) | tap card body (kept) **or** Edit in ⋯ menu |
| **Edit · Share · Delete** (+ iOS: Duplicate, Move, Snooze, Timer) | hover icon row | **⋯ overflow menu** (NEW), plus swipe + long-press as accelerators |
| **Reorder / move quadrant** | drag handle | drag (long-press) |

Decision (confirmed with owner): iOS **keeps tap-body-to-edit.** Web's inert body is an *absence* of behavior, not a learned rule, so adding edit-on-body-tap is additive and contradicts nothing; meanwhile "tap a row to open it" is a strong iOS convention worth preserving. The disc's tap takes precedence within its own hit area, exactly as the web circle does.

## 5. Detailed design

### 5.1 Tappable completion disc — `TaskCardView`

`TaskCardView` is the single card view rendered by both the iPhone row and the iPad cell, so it is the right place for the shared change.

- Wrap `completionDisc` in a tap target that invokes a new optional `onToggle: (() -> Void)?` callback. Containers pass `{ actions.toggle(task) }`, which already performs the success haptic, confetti (`onCompleted`), and recurring-task rollover (`store.toggleComplete`). **No new completion logic is introduced.**
- Remove `.accessibilityHidden(true)` from the disc; expose it with a "Complete"/"Uncomplete" accessibility label.
- Expand the tap target to ≥44pt around the 28pt disc (padding inside the trailing control), per [`spec.md` §12.3](../../../spec.md).
- When `onToggle` is `nil` (previews, any non-interactive host), the disc renders exactly as today — pure decoration. This preserves `TaskCardView`'s use in isolation.

### 5.2 Persistent `⋯` overflow menu — `TaskCardView`

- Add a trailing `Menu` labeled with the SF Symbol `ellipsis`, placed just inboard of the disc, rendered in a quiet ink tone so it does not compete visually.
- Its content is the shared `TaskRowMenu` (see 5.3): Edit · Duplicate · Share · Complete/Uncomplete · Start/Stop Timer · Snooze ▸ · Move to ▸ · Delete.
- Surfaced via a new optional `menu` parameter on `TaskCardView` (a `@ViewBuilder` or a small config). When absent, no ⋯ is shown.

### 5.3 Shared menu — extract `TaskRowMenu`

`rowMenu` in [`TaskListRow.swift`](../../../App/Matrix/TaskListRow.swift) and `cellMenu` in [`QuadrantCell.swift`](../../../App/Matrix/QuadrantCell.swift) are near-identical today. Extract a single `TaskRowMenu(task:actions:onEdit:)` view used by:
1. the long-press **context menu** (iPhone) / swipe **menu** (iPad `SwipeRevealRow`),
2. the new **⋯ button**.

This guarantees the three entry points can never drift apart, and removes the existing duplication (a targeted cleanup of code we are already touching).

### 5.4 Edit-mode (multi-select) gating

During multi-select, a row tap must toggle **selection**, not fire the disc or the ⋯ menu.
- **iPad** ([`QuadrantCell.swift`](../../../App/Matrix/QuadrantCell.swift)) already swaps the row for a selection `Button` wrapping a non-interactive `TaskCardView` when `isSelecting` — so pass `onToggle: nil` / no `menu` in that branch and nothing fires. ✔ by construction.
- **iPhone** ([`TaskListRow.swift`](../../../App/Matrix/TaskListRow.swift)) gates the disc/⋯ on `editMode` the same way the body `TapGesture` is masked today (`including: isSelecting ? .subviews : .all`).

### 5.5 Gesture precedence

The disc button and the ⋯ menu sit inside a card that also has a body `TapGesture { onEdit }`. The disc/menu must win within their own hit areas.
- Approach: make the disc and ⋯ real `Button`/`Menu` controls and **scope the body tap to the content region only** (apply the body `TapGesture`/`onTapGesture` to the leading content stack, not the trailing controls) — rather than relying solely on subview gesture masking. This avoids the body gesture swallowing taps meant for the disc.
- This is the one non-trivial implementation detail; the plan will pin the exact view structure.

### 5.6 Affected files

- `App/Matrix/TaskCardView.swift` — tappable disc, ⋯ menu, optional `onToggle` + `menu` params, a11y.
- `App/Matrix/TaskListRow.swift` (iPhone) — pass `onToggle`/`menu`; scope body tap; edit-mode gating; adopt `TaskRowMenu`.
- `App/Matrix/QuadrantCell.swift` (iPad) — pass `onToggle`/`menu` in the non-selecting branch; adopt `TaskRowMenu`.
- `App/Matrix/TaskRowMenu.swift` — **new**, extracted shared menu.
- (`FilteredTaskListView` / smart-view results inherit the change for free via `TaskListRow`.)

## 6. Accessibility

- The disc becomes a labeled control ("Complete"/"Uncomplete"); the existing combined `accessibilityElement` + `.accessibilityActions` (Complete/Edit/Duplicate/Delete/Snooze/Timer) stay, so VoiceOver users keep the rotor-action path regardless of the visual buttons.
- ⋯ gets an accessibility label ("More actions").
- Hit targets ≥44pt; respects Dynamic Type (card already scales) and the existing Reduce Motion handling.

## 7. Testing

- **GSDKit (`swift test`):** no new logic to unit-test — completion/recurrence/haptic paths already covered via `TaskStore`/`RecurrenceEngine` tests. Confirm the suite still passes (no logic moved into the package).
- **Build gate:** clean `xcodebuild` for **both** an iPhone and an iPad simulator (co-equal targets).
- **Manual smoke (per platform):**
  1. Tap the disc on an active task → completes (strikethrough, filled disc, success haptic, confetti); tap again → uncompletes.
  2. Complete a **recurring** task via the disc → next instance appears.
  3. Tap the card body → editor opens (unchanged).
  4. ⋯ → every action present and correct; matches the long-press context menu item-for-item.
  5. Enter multi-select → tapping the disc/⋯ toggles **selection**, not completion/menu; Done clears selection.
  6. Swipe actions and long-press context menu still work.
  7. VoiceOver: disc and ⋯ are reachable and correctly labeled; rotor actions intact.

## 8. Risks

- **Gesture precedence** (5.5) — the body tap could swallow disc/⋯ taps if the view structure is wrong. Mitigation: scope the body gesture to the content region; verify by smoke test on both targets.
- **Trailing-edge crowding** — disc + ⋯ on a narrow phone card. Mitigation: ⋯ rendered quietly; verify spacing at large Dynamic Type sizes.

## 9. Open questions

- None blocking. (Card-body-tap behavior resolved: keep tap-to-edit.)

## 10. Out of scope / possible follow-ups

- A one-time coachmark ("tap ○ to complete · ⋯ for more") — only if smoke testing suggests the ⋯ isn't discovered. Not in this change.
- Revisiting web-side affordances for closer symmetry — separate effort in the web repo.
