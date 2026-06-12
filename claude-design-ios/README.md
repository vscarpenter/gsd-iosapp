# Handoff: GSD Editorial Visual Language

## Overview

This package redesigns the visual language of the **GSD iOS app** (Get Stuff Done — the privacy-first Eisenhower-matrix task manager) to match its stated brand: **Editorial · Calm · Focused**. It is a *visual/style* redesign — no behavior, data model, navigation, or feature changes. Every screen keeps its current function; what changes is type, color, surface, spacing, iconography treatment, and the interaction polish layer.

**The core idea, in three moves:**
1. **Retire system-blue.** Today Browse, Dashboard, Settings, the command palette, and the charts lean on iOS system-blue, which reads generic and competes with the matrix. Remove it. The **only** strong color in the app becomes the four quadrant pigments. Chrome, nav icons, and links go quiet graphite/ink; a single restrained "tint" is used only for true actions.
2. **One editorial voice.** Apple **New York** (the system serif, free) handles headlines, page titles, quadrant names, sheet titles, and big metric numerals. **SF** handles all body, labels, and data. This extends the serif already used on the matrix headers to the whole app.
3. **Warm paper neutrals.** Replace flat iOS gray with a warm paper ramp (reads composed, unhurried). A cool ramp is included as a one-token-swap alternative.

## About the design files

The files in this bundle (`GSD Design Language.html` + `styles/tokens.css`) are **design references created in HTML** — a prototype/spec showing the intended look and behavior. They are **not** production code to copy. Your task is to **recreate these designs in the existing SwiftUI codebase** (`gsd-iosapp`, SwiftUI throughout, `GSDKit` shared package) using its established patterns — `Color`, `Font`, `View` modifiers, `List`/`Form`, `Charts`, `swipeActions`, `contextMenu`, etc.

Open `GSD Design Language.html` in a browser to see the full spec: foundations, typography, color, components, all applied screens (light + dark), motion notes, the app-icon concept, and copy-paste SwiftUI token snippets. `styles/tokens.css` holds the exact values as CSS custom properties — every `--token` maps to a value listed in **Design Tokens** below.

## Fidelity

**High-fidelity.** Final colors (exact hex, light + dark), typography, spacing, radii, and interactions are specified. Recreate pixel-faithfully using SwiftUI. The HTML phone mockups are drawn at true iPhone scale (390 pt wide) so px ≈ pt.

---

## Where this lands in the codebase

The app already has the right scaffolding. The redesign is mostly **token + component-styling** work:

| File (in `gsd-iosapp/App/Theme/`) | Change |
|---|---|
| `QuadrantStyle.swift` | Replace the four `accent(_:)` hex pairs with the refined values below. Keep the `Color(light:dark:)` initializer and `symbol(_:)` SF Symbols as-is. |
| `Theme.swift` | Already has `Font.serif(_:)` (New York via `design: .serif`) and the `AppTheme` enum — keep. **Add** a `Surface` color enum (neutrals/ink/success) per the snippet below. |

Then apply `Surface.*` and `QuadrantStyle.accent(_:)` across the existing views (Matrix, Browse, Dashboard, Editor, Settings, Palette, Onboarding, Archive). The biggest single edit is **deleting ad-hoc `.tint(.blue)` / `Color.blue` / `.accentColor` usages** and replacing them with `Surface.ink` (chrome), `QuadrantStyle.accent` (quadrant identity), or `Surface.tint` (genuine actions only).

---

## Design Tokens

### Quadrant pigments (the only strong color)
Refined from the original rust/ocean/olive/gray into a harmonized, ink-like set. **Light / Dark** adaptive.

| Quadrant | Role | Light | Dark | Name |
|---|---|---|---|---|
| `urgentImportant` — **Do First** | Urgent · Important | `#B23A2E` | `#E0705F` | Rust |
| `notUrgentImportant` — **Schedule** | Not urgent · Important | `#2C6680` | `#6FAACB` | Tide |
| `urgentNotImportant` — **Delegate** | Urgent · Not important | `#8A6A22` | `#CFB266` | Ochre |
| `notUrgentNotImportant` — **Eliminate** | Neither | `#6F685F` | `#A9A096` | Slate |

**Tag/chip washes** (tinted card backgrounds for tags & the editor's quadrant picker):
`q1-wash` `#F4E4E0`/dark `#3A211D` · `q2-wash` `#E1ECF1`/`#173039` · `q3-wash` `#F0E9D8`/`#322B17` · `q4-wash` `#ECE9E3`/`#2A2620`

### Neutrals — WARM (primary)
| Token | Light | Dark | Use |
|---|---|---|---|
| `paper` | `#F4F1E9` | `#17150F` | Page / screen background |
| `sunken` | `#ECE7DC` | `#100E0A` | Grouped / inset fills, tracks |
| `surface` | `#FFFFFF` | `#221E17` | Raised cards, sheets |
| `surface-2` | `#FBF9F3` | `#1B1812` | Secondary surface, circular buttons |
| `hairline` | `#E3DDD0` | `#322D24` | Separators, card borders |
| `hairline-strong` | `#D8D1C1` | `#423B2F` | Stronger borders, unselected toggles |
| `ink` | `#211E1A` | `#F1ECE2` | Primary text |
| `ink-2` | `#6E6760` | `#A79F92` | Secondary text |
| `ink-3` | `#A49B8D` | `#6F685B` | Tertiary text, quiet icons |

### Neutrals — COOL (optional alternate; swap these four to flip the whole app)
`paper` `#F1F2F4` · `sunken` `#E8EAEE` · `hairline` `#E1E3E8` · `ink-2` `#62666D` (light values; surface stays `#FFFFFF`).

### Functional
| Token | Light | Dark | Use |
|---|---|---|---|
| `success` | `#3E7D52` | `#6FB07F` | Completion, "completed" chart series, 100% progress |
| `alert` | `#B23A2E` | `#E0705F` | Overdue, Delete, destructive |
| `tint` | `#2C6680` | `#6FAACB` | The single interactive tint — links/actions ONLY (Sync Now, Restore, Capture link). Not chrome. |

### Typography (px == iOS pt)
Headlines/numerals = **New York** (`.system(_, design: .serif)`), everything else = **SF** (system default). Use Dynamic-Type text styles, never fixed sizes, in code.

| Style | Font | Size / Weight | iOS text style |
|---|---|---|---|
| Large Title | New York | 34 / semibold | `.largeTitle` + `.serif` |
| Title 1 (sheet titles) | New York | 28–30 / semibold | `.title` + `.serif` |
| Title 3 (quadrant names, card states) | New York | 20 / semibold | `.title3` + `.serif` |
| Metric numerals (Dashboard) | New York | 30 / semibold, tabular | `.serif` + `.monospacedDigit` |
| Headline (task titles) | SF | 17 / semibold | `.headline` |
| Body | SF | 17 / regular | `.body` |
| Subhead (descriptions) | SF | 15 | `.subheadline` |
| Footnote (meta, tags, dates) | SF | 13 | `.footnote` |
| Caption (section labels) | SF | 12, uppercase, tracking .08em | `.caption` |

### Spacing — 4-pt grid
`4` hairline gaps · `8` chip padding · `12` in-card rhythm · `16` card padding · `20` screen inset · `24` section gap · `32` between quadrants.

### Shape (always continuous corners — the iOS squircle)
Cards & groups **22** · sheets **26** · chips/buttons/circular-buttons **pill** · inputs **16** · tiles **8–12**. Hit targets **≥ 44**.

### Elevation (soft, matte, warm-tinted — no glassmorphism, no glow)
- **Card:** `0 1px 2px rgba(40,33,22,.05), 0 8px 24px rgba(40,33,22,.06)` (dark: black at .35/.40)
- **Pop** (menus, command palette): `0 12px 40px rgba(40,33,22,.18)`
- **Sheet:** upward soft shadow.
- In SwiftUI, approximate with one subtle `.shadow(color:radius:y:)` + a `hairline` stroke; favor borders over heavy shadows.

---

## Screens / Views

> Each screen exists in the HTML at true scale. Descriptions below are self-sufficient; reference the HTML for exact composition.

### 1. Matrix (hero)
- **Background** `paper`. **Status bar**, then a **nav row**: circular `search` button (left, `surface-2` fill, hairline border, 44×44) and a circular "show completed" toggle (right). The toggle is `surface-2` when off; `tint`-filled white-glyph when on.
- **Capture bar:** pill, `surface` fill, hairline border, soft card shadow. Placeholder `ink-3`: `Capture a task…` followed by monospace chips `!!` `*` `#tag` (sunken background). A trailing **quadrant chip** ("Eliminate" with trash glyph, in `q4`) shows the current override target and recolors live as shorthand is typed.
- **Per quadrant:** a **section header** = New York title3 in the quadrant accent + the quadrant SF Symbol (same color) + live count (right, `ink-3`, tabular). Followed by a **group**: one rounded `surface` panel (radius 22) holding the quadrant's task cards separated by hairlines. Empty quadrants show a **dashed prompt row** instead (see Empty states).
- **Spacing:** 32 between quadrants, 12 header-to-group.
- **Tab bar:** floating pill `surface` shell (hairline, card shadow) with 4 tabs; active tab label `ink`, active icon in the relevant accent (Matrix uses `q1`).

### 2. Task card (the core component, all states)
Anatomy: a **3 px accent spine** (quadrant color) inset at left; **title** SF headline (17/semibold); optional **2-line description** (`ink-2`, links in `ink-3`); a **meta row** (footnote) for tags/due/badges; a **completion circle** top-right (28×28, 2 px `hairline-strong` ring).
- **Default:** as above.
- **Completed:** title strikethrough + `ink-3`; description `ink-3`; circle becomes a **filled accent disc with a white check**.
- **Tags:** pill chips. In a card they use the quadrant **wash** background + accent text; generic chips elsewhere use `sunken`/`ink-2`.
- **Subtask progress:** a mini track (84×6, `sunken`) + accent fill + `done/total` (e.g. `3/5`). At 100% the fill and label go `success`.
- **Due date:** calendar glyph + relative text. Normal `ink-3`; **Due today** in `tide`/q2 semibold; **overdue** in `alert` with a warning glyph.
- **Live timer:** a pulsing accent dot + tabular `HH:MM:SS` in the quadrant accent (updates each second via `TimelineView`).
- **Recurrence:** a repeat glyph in `ink-3`.
- **Blocked:** whole card at ~62% opacity + a lock badge "Blocked by N" (`ink-3`).
- **Captured link:** the URL shows as the description in `ink-3`.

### 3. New Task editor (sheet)
- Presented as a detented sheet (`.medium`/`.large`) over a dimmed board. **Grabber**, then a nav row (`Cancel` / `Save`; Save disabled & `ink-3` while title empty).
- **New York 28–30 title** "New Task". **Title input** (`surface`, hairline, radius 16).
- **Quadrant** field: a **2×2 picker** mirroring the matrix — each cell has the quadrant icon + name; the **selected** cell fills with that quadrant's wash + accent border + accent text; unselected cells get a faint accent-tinted border. Field labels are footnote/semibold `ink-3`.
- **Tags** token field; **Notes** textarea; **Due date** = a "Has due date" toggle + preset pills (`None`, `Today`, `This week`, `Next week`; selected preset uses q2 wash); **Repeat** = Recurrence row (`Never ⌄`). Subtasks/Estimate/Snooze/Dependencies follow the existing editor order.

### 4. Browse / Smart Views
- Large New York "Browse". An **Archive** row card, then a `Built-in views` caption label, then a grouped list. **Each row:** an SF Symbol icon + name (SF body) + count (`ink-3`, tabular) + chevron. **Icons are graphite (`ink-2`) by default** — tinted with an accent *only* where the view has identity (Today's Focus = q1, This Week = q2, Overdue = alert, This Week's Wins = q3, Ready to Work = q2). This is the key de-blue-ing.

### 5. Dashboard (charts re-skinned onto the system)
- New York "Dashboard". A **2-col stat grid** of cards (`surface`): each has a footnote label with a small SF Symbol + a **big New York numeral** (30, tabular). The Streak card carries a small `q1` flame.
- **Completion Trend:** line chart with a 7/30/90 segmented control. **Completed = `success`** (solid line + ~8% area fill); **Created = `ink-3`** (thin dotted line). Gridlines `hairline`, axis labels footnote `ink-3`. *(Replaces the old bright green/blue.)*
- **By Quadrant:** a donut using the **four pigments** (Do First/Rust, Schedule/Tide, Delegate/Ochre, Eliminate/Slate); center shows active total in New York; legend below with counts colored to match. *(Replaces the old blue/green/magenta/orange.)*
- **Top Tags:** horizontal bars in **tide** (`q2`, ~82% opacity) on `sunken` tracks, with value labels. *(Replaces bright blue.)*
- **Upcoming Deadlines:** title + date rows; overdue dates in `alert`.
- Build with **Swift Charts**; pass the same four accent `Color`s.

### 6. Settings
- New York "Settings". Grouped `surface` cards with uppercase footnote section labels (`Appearance`, `Account`, `Archive`, …). Rows: name in `ink`, value/`⌄`/chevron in `ink-3`; toggles use `success` when on, `hairline-strong` track when off.
- **Actions** carry a leading icon + label: ordinary actions (Sync Now, Archive Now) in **`tint`**; **destructive** (Sign Out, Erase All Data) in **`alert`**. No blanket blue.

### 7. Command Palette (⌘K)
- A blurred-scrim overlay over the dimmed board. `Close` pill, New York "Commands", a search field (`surface`), then sectioned grouped lists (`Smart Views`, `Actions`, …). Row text `ink` (not blue); icons graphite, accent-tinted only for identity views as in Browse.

### 8. iPad — 2×2 board (`NavigationSplitView`)
- **Sidebar** (`surface-2`): brand mark; Matrix / Dashboard; a `Smart Views` group (pinned first) with counts; `Library` (Archive, Settings). Selected item = `sunken` fill, icon in `q1`.
- **Content:** a toolbar with New York "Matrix" + the capture pill, then a true **2×2 grid** filling the column — Q1 top-left, Q2 top-right, Q3 bottom-left, Q4 bottom-right. Each cell is a `surface` panel with its accent header + scrollable card list. **Drag a card across a boundary to reclassify** (`urgent`/`important`). The editor opens in an **inspector** (third column), not a sheet.

### 9. Onboarding (first run — 4 skippable screens)
Centered, paper background, page dots, a `Skip` top-right on every screen.
1. **Welcome** — the 2×2 app-mark hero, New York "Get the right things done.", a one-line lead, primary `Get started` (ink-filled pill), `Skip`.
2. **The Matrix** — a 2×2 axes diagram (pigment-wash tiles labeled Do First/Schedule/Delegate/Eliminate with `More urgent →` / `More important →` axes), title "Four quadrants, one decision.", `Next`.
3. **Capture shorthand** — a sample capture field (`Call my wife !! #family`) + a legend mapping `!!` `!` `*` `#tag`, `Next`.
4. **Privacy & sync** — a lock mark, "Yours, and only yours.", the on-device/optional-sync copy; primary `Start using GSD`, quiet **secondary** `Sign in to sync` in `tint` (never the default).
- Re-showable from Settings → About → *Show Onboarding Again*. Reduce Motion → cross-fade, no animated illustration.

### 10. Empty states
- **Anatomy:** centered — one quiet SF Symbol (`ink-3` on a `sunken` 60-pt tile; tinted only to reassure, e.g. green check for "nothing overdue"), a New York title3 headline, one `ink-2` sentence, and **at most one** action (in `tint`).
- **In-context empties** (a quadrant inside a non-empty matrix) use a **dashed prompt row** (`1px dashed hairline-strong`, radius 22, a circled `+`, copy like "No fires right now. **Add to Do First**") — not a full-screen takeover.
- **Per-surface copy** (exact strings):
  - Empty matrix (brand new): **"Capture your first task"** / "Type in the field above — try `Call my wife !! #family`."
  - Do First: **"No fires right now."** / Add to Do First
  - Schedule: **"Nothing scheduled yet."** / Add to Schedule
  - Delegate: **"Nothing to hand off."** / Add to Delegate
  - Eliminate: **"Nothing to drop."** / Add to Eliminate
  - Overdue Backlog: **"Nothing overdue."** / "You're all caught up."
  - This Week's Wins: **"No wins logged yet."** / "Completed tasks from the last 7 days show here."
  - Dashboard: **"No stats yet"** / "Complete a few tasks and your trends will appear."
  - Search no results: **"No tasks match "…""** / "Try a different word, tag, or quadrant."
  - Archive: **"Nothing archived."** / "Completed tasks you archive will live here."

### 11. Archive
- New York "Archive" nav title, a back chevron + search. A note line ("N completed tasks · read-only…"). Rows are **dimmed (~72%)**, strikethrough titles, accent spine, and an `Archived <date>` meta line. Read-only (no inline edit). **Swipe → Restore** (`tint`) and **Delete** (`alert`), both with undo.

---

## Interactions & Behavior (motion)

All motion respects **Reduce Motion** (confetti suppressed; transitions become cross-fades).

- **Completion:** tap or leading-swipe → circle fills with the quadrant accent + draws a check; **`.success` haptic**; card eases to its dimmed/sorted slot; confetti burst from center (~120 + 2×60 particles) via `Canvas`+`TimelineView` or a light package. Spring ≈ `response 0.34, dampingFraction 0.8`.
- **Swipe actions:** **leading → Complete/Uncomplete** (green). **trailing ← Snooze** (slate) **+ Delete** (rust, confirms once). Full-swipe past threshold triggers without lifting; `.impact(.light)` haptic at threshold. Use SwiftUI `.swipeActions`.
- **Long-press / context menu** (`.contextMenu`): lifts the card; items **Edit · Complete · Start/Stop timer · Snooze · Duplicate · Share · Move to quadrant · Delete** (destructive last, role `.destructive` → rust). Snooze/Move open submenus (presets / four quadrants). On iPad these are also the right-click menu.
- **Capture → classify:** as shorthand is typed the quadrant chip recolors/relabels live (`!!`→Do First); on submit the field flashes the accent, the new card drops into its quadrant, focus is retained for serial capture. `.transition(.move(.top).combined(with:.opacity))`.
- **Sheets & counts:** editor rises as a detented sheet over a dimmed board; quadrant counts roll via `.contentTransition(.numericText())`; timer elapsed ticks each second via `TimelineView`.

## State Management
No new state introduced by this redesign. It reuses existing app state (tasks, `showCompleted`, theme preference, quadrant filters, sync status). The only additions are presentation-level: theme is already `light/dark/system` (`AppTheme`); the warm/cool neutral choice is a **compile-time token set** (or an optional preference) — default **warm**.

## Assets
- **Icons:** all icons in the HTML are placeholders that map to **SF Symbols** — use SF Symbols in the app (`flame.fill`, `calendar`, `person.2.fill`, `trash`, `magnifyingglass`, `checkmark.circle`, `plus`, `chevron.right`, `lock`, `arrow.triangle.2.circlepath`, `scope`/`target`, `exclamationmark.triangle`, `sparkles`, `trophy`, `bolt.fill`, `archivebox`, `square.grid.2x2`, `chart.bar`, `gearshape`, `clock`, `square.and.arrow.up`, `square.on.square`, `pencil`, `arrow.uturn.backward`, `arrow.up.and.down.and.arrow.left.and.right`). `QuadrantStyle.symbol(_:)` already defines the four quadrant symbols — keep them.
- **App icon concept:** a 2×2 of the quadrant pigments on warm paper, with a single white check on the Do-First (rust) tile (light & dark variants in the HTML icon section). Provided as a *concept* — produce final assets in your icon pipeline (`gsd-iosapp/Design/icon/`).
- **Fonts:** New York and SF both ship with iOS — no font files to bundle.

## SwiftUI starting point

```swift
// QuadrantStyle.swift — replace the accent values
static func accent(_ q: Quadrant) -> Color {
    switch q {
    case .urgentImportant:       Color(light: 0xB23A2E, dark: 0xE0705F) // Rust  · Do First
    case .notUrgentImportant:    Color(light: 0x2C6680, dark: 0x6FAACB) // Tide  · Schedule
    case .urgentNotImportant:    Color(light: 0x8A6A22, dark: 0xCFB266) // Ochre · Delegate
    case .notUrgentNotImportant: Color(light: 0x6F685F, dark: 0xA9A096) // Slate · Eliminate
    }
}

// Theme.swift — add the neutral/functional surface ramp (warm)
enum Surface {
    static let paper    = Color(light: 0xF4F1E9, dark: 0x17150F)
    static let sunken   = Color(light: 0xECE7DC, dark: 0x100E0A)
    static let surface  = Color(light: 0xFFFFFF, dark: 0x221E17)
    static let surface2 = Color(light: 0xFBF9F3, dark: 0x1B1812)
    static let hairline = Color(light: 0xE3DDD0, dark: 0x322D24)
    static let ink      = Color(light: 0x211E1A, dark: 0xF1ECE2)
    static let ink2     = Color(light: 0x6E6760, dark: 0xA79F92)
    static let ink3     = Color(light: 0xA49B8D, dark: 0x6F685B)
    static let success  = Color(light: 0x3E7D52, dark: 0x6FB07F)
    static let alert    = Color(light: 0xB23A2E, dark: 0xE0705F)
    static let tint     = Color(light: 0x2C6680, dark: 0x6FAACB)
}

// Headlines use the existing helper:
Text("Do First").font(.serif(.title3).weight(.semibold)).foregroundStyle(QuadrantStyle.accent(.urgentImportant))
Text("Finalize AWS deck").font(.headline).foregroundStyle(Surface.ink)   // SF
```

## Suggested implementation order
1. Tokens: update `QuadrantStyle.accent`, add `Surface`. Set the app/window tint away from system blue.
2. Task card component (covers most of Matrix, Browse lists, Archive).
3. Matrix screen (headers, capture bar, groups, empty prompts).
4. Browse + Settings + Command Palette (de-blue: graphite icons, tint only for actions).
5. Dashboard charts (Swift Charts re-skin to the four accents + success/graphite).
6. Editor sheet (2×2 quadrant picker).
7. Gestures (swipeActions, contextMenu) + Archive.
8. Onboarding + empty states.
9. iPad split-view 2×2 + inspector.
10. App icon.

## Files in this bundle
- `GSD Design Language.html` — the full visual spec + all applied screens (open in a browser).
- `styles/tokens.css` — every design token as a CSS custom property (source of truth for exact values).
- `README.md` — this document (self-sufficient).
