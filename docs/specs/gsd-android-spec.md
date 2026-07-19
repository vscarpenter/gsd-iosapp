# GSD Task Manager — Native Android Product Specification

- **Date:** 2026-07-19
- **Status:** Draft for review
- **Author:** Vinny Carpenter (with Claude)
- **Purpose:** A self-contained product specification for building the GSD Task Manager as a **native Android app (Kotlin + Jetpack Compose)** for phones, tablets, and foldables. This document is written to be handed to a fresh Claude Code session in a new, empty repository (suggested name: `gsd-androidapp`). It assumes **no access to the iOS or web codebases** — every behavioral rule, data limit, protocol detail, and design token needed to build the app is inlined here.
- **Provenance:** GSD ships today as a web app (Next.js, gsdtaskmanager.com) and a native iOS/iPadOS/Mac Catalyst app (SwiftUI). This spec was distilled from the shipped iOS app (v2.2.0) and its behavior authority, and reconciled against the live implementation — where the original iOS spec and the shipped app disagree, **the shipped app is authoritative** and this document reflects it.

> **Reader note.** Where this spec says "matches iOS/web," the relevant behavior is described in full in this document; you do not need the other codebases. Enumerated values (recurrence types, archive tiers, snooze durations, field limits, wire field names, color values) are authoritative as written.

---

## 1. Overview & Vision

GSD ("Get Stuff Done") Task Manager is a **privacy-first, offline-first Eisenhower-matrix task manager**. Tasks are classified along two axes — **urgent** and **important** — into four quadrants, helping the user decide what to *do first*, *schedule*, *delegate*, or *eliminate*. The app answers one question well: *what do I work on next?*

The product's defining characteristics, which the Android app must preserve:

- **Privacy-first & offline-first.** All data lives on-device. The app is fully usable with no account and no network. Cloud sync is strictly **optional** and opt-in. This is a *correctness constraint*, not a preference.
- **Frictionless capture.** A persistent capture bar with a natural-language shorthand (`!`, `!!`, `*`, `#tag`) lets the user add and classify a task in one keystroke-light gesture.
- **Depth under a calm surface.** Behind the 2×2 grid sit recurrence, subtasks, dependency graphs, time tracking, analytics, and multi-device sync.
- **Editorial, calm aesthetic.** A serif display typeface for headings, generous spacing, restrained color — the four quadrant accents carry the only strong color in the app.

### Why native (not Flutter / not React Native / not a wrapped PWA)

The same reasoning that produced the native iOS app: a first-class platform citizen — instant launch, native gestures, home-screen widgets, share-sheet integration, exact-alarm reminders, TalkBack, predictive back — none of which a wrapper delivers convincingly. The Android app **reimagines interactions around Android idioms** (Material components restyled to GSD's tokens, bottom navigation, snackbars, notification actions, adaptive layouts) rather than transliterating iOS or web layouts. "Native, not ported" is a founding product principle.

### The GSD ecosystem this app joins

| Client | Platform | Status |
|---|---|---|
| GSD web app | gsdtaskmanager.com (Next.js + Dexie/IndexedDB) | shipped |
| GSD iOS app | iPhone / iPad / Mac Catalyst (SwiftUI + GRDB) | shipped, App Store |
| GSD MCP server | Claude Desktop (reads/writes the shared backend) | shipped |
| **GSD Android app** | **phones / tablets / foldables** | **this spec** |

All clients share one self-hosted **PocketBase** backend and one wire schema. A task captured on Android must round-trip losslessly through the web app, the iOS app, and the MCP server. Section 4 states the compatibility contract; treat it as non-negotiable.

### Success criteria

1. A user can capture, classify, edit, complete, and organize tasks entirely offline, in a UI that feels **designed for Android, not ported** — while still unmistakably GSD.
2. Signing in syncs tasks bidirectionally with the existing backend, the web app, the iOS app, and the user's other devices, with conflicts resolved deterministically (last-write-wins).
3. The app ships the full feature set: matrix, capture parser, recurrence, subtasks, dependencies, time tracking, snooze, archive, smart views, search + command palette, analytics dashboard, import/export, local reminders, undo-delete — plus Android-native surfaces (widget, share target, app shortcuts, notification actions).
4. The app passes Google Play review with an accurate Data Safety form.

---

## 2. Goals & Anti-Goals

### Goals

- Full behavioral parity with the shipped GSD apps, reimagined with Android **interaction patterns**.
- Bidirectional multi-device sync with the existing PocketBase backend, byte-compatible with the web and iOS clients.
- Native surfaces: a Glance home-screen widget, a share target, app shortcuts, deep links, reminder notifications with action buttons.
- **Phones and large screens (tablets / unfolded foldables) as co-equal first-class targets** with genuinely adaptive layouts — the Android analog of the iPhone/iPad co-equality.
- Play-Store-ready: accurate Data Safety declarations, modern target API, accessibility baseline.

### Anti-Goals (explicitly out of scope for this version)

- **No Wear OS app.** (Matches the iOS "no Watch app" anti-goal.)
- **No Material You dynamic color.** Wallpaper-derived theming would dissolve the rationed quadrant-accent brand. The app ships its own fixed light/dark palettes. (A monochrome themed **launcher icon** layer is the one exception — it's a launcher convention, not app theming; see §12.5.)
- **No changes to the existing backend or MCP server.** The app consumes the existing PocketBase `tasks` collection as-is.
- **No real-time collaborative editing / shared task lists.** Sync is single-user, multi-device.
- **No streaks, badges, points, or gamification.** GSD measures progress honestly; the iOS dashboard's streak tiles were deliberately removed by owner decision. Do not add them here.
- **No analytics/tracking SDKs.** Local-only by default; any diagnostics would be opt-in (none at launch).

---

## 3. Platforms & Technical Foundation

- **Min SDK:** **31** (Android 12). Rationale: native splash-screen API, exact-alarm permission model, mandatory notification channels, and broad 2026 device coverage. **Target SDK: latest stable.**
- **Devices:** phones, tablets, and foldables. Layouts adapt by **window size class** (compact / medium / expanded); tablets and unfolded foldables get a true 2×2 matrix, drag-and-drop, and hardware-keyboard shortcuts. Support portrait and landscape everywhere; no locked orientations.
- **Distribution:** Google Play (plus sideloadable APK builds for testing).
- **Application ID:** `dev.vinny.gsd` (matches the iOS bundle id family; final say is the owner's at Play listing time).
- **Languages:** English at launch; never hard-block localization (all UI strings in `strings.xml` resources, no concatenated sentences).

### Recommended technical foundation (implementation guidance, not product requirement)

- **Language / UI:** Kotlin, **Jetpack Compose** throughout, Material 3 components restyled with GSD tokens (§5). Compose Navigation with `material3-adaptive` for size-class scaffolding. Edge-to-edge; predictive back enabled.
- **Local store: Room (SQLite)** as the on-device source of truth. Rationale: the app requires a hand-rolled REST + SSE last-write-wins sync engine (§9); Room gives explicit row control and `Flow`-based change observation that maps 1:1 to the web app's Dexie + sync-queue model and the iOS app's GRDB store. Versioned migrations from day one.
- **Networking / PocketBase client:** there is **no official PocketBase Kotlin SDK** worth depending on for this narrow use. Build a small client: REST over **OkHttp + kotlinx.serialization**, realtime over OkHttp SSE (`EventSource`), OAuth via **Custom Tabs** (`androidx.browser`). This is net-new, higher-risk code and gets its own milestone and test surface (§16).
- **Dates:** `java.time` (available since API 26). All wire timestamps are ISO-8601 strings with timezone offset (§4.3).
- **Module structure** — the layered architecture is the design; the dependency direction is enforced by Gradle module boundaries, mirroring the iOS `GSDKit` package that made that app testable:

| Module | Responsibility | Depends on |
|---|---|---|
| `:core:model` | Pure Kotlin/JVM domain — Task, Quadrant, capture parser, recurrence, dependency graph (BFS), filtering, validation, analytics, import/export. **Zero Android dependencies** — unit-tested on the JVM in milliseconds. | *nothing* |
| `:core:store` | Room persistence — database + versioned migrations, per-entity repositories over `Flow`, and the single **TaskStore** mutation path that stamps `updatedAt` via an injected clock and enqueues sync. | `:core:model` + Room |
| `:core:sync` | PocketBase REST + SSE sync — a pure **SyncEngine** (pull / push / deletion-reconcile / LWW, fully unit-tested against recorded fixtures), OAuth2-PKCE auth, JWT handling, wire mappers. | `:core:model` + `:core:store` |
| `:app` | Compose UI, widget (Glance), share target, notifications, deep links, composition root. Thin. | all of the above |

- **Concurrency:** Kotlin coroutines + `Flow`. The sync engine serializes its runs (one sync at a time; concurrent triggers coalesce).
- **DI:** a **manual composition root** in the `Application`/root activity (constructor injection, no Hilt/Koin). The iOS app wires everything explicitly in one `init()`; match that simplicity. One database, shared repositories handed to both the TaskStore and the SyncEngine so a pulled write reaches UI observers and a local mutation reaches the sync drain.
- **Background:** WorkManager for the periodic maintenance job (auto-archive sweep + opportunistic sync, §11.5); `AlarmManager` exact alarms for reminders (§11.2).
- **Token storage:** Android **Keystore-encrypted** storage (encrypt the PocketBase JWT with a Keystore key; persist ciphertext in DataStore). Never plain SharedPreferences, never logged.
- **The fast feedback loop is `:core:model` + `:core:sync` JVM tests, not the emulator.** `./gradlew :core:model:test` must stay sub-second-fast and cover all pure logic. Instrumented/emulator tests are for Room migrations and UI smoke only.

### Engineering standards

Adopt the same agentic coding standards file the iOS repo uses (`coding-standards.md` — spec-driven development, TDD red/green/refactor, conventional commits, small functions, no speculative abstraction). Copy it into the new repo unchanged; it is platform-agnostic.

---

## 4. Compatibility Contract (non-negotiable)

Everything in this section is shared with the web app, the iOS app, and the MCP server. Any deviation breaks cross-device sync silently. When in doubt, this section wins over convenience.

### 4.1 IDs

- Task and entity IDs are **URL-safe nanoid-style strings**. Generate with the nanoid default alphabet (`A-Za-z0-9_-`).
- Lengths in practice: tasks use nanoid **21** (the default); time entries **8**; smart views **12**; minimum accepted ID length anywhere is **4**. Built-in smart views use fixed human-readable IDs (§8.13).
- IDs are generated **client-side** and never re-issued; they are the cross-client join key (`task_id` on the wire).

### 4.2 The wire schema

The PocketBase `tasks` collection schema in §9.1 — snake_case field names, flattened `time_entries`, `client_updated_at` as the LWW key — must be implemented exactly. The Android app must not add, rename, or repurpose wire fields.

### 4.3 Timestamps

- Wire/export timestamps are **ISO-8601 strings with timezone offset and millisecond precision** (e.g. `2026-07-19T14:03:22.114-05:00`); internally store epoch millis or `Instant`.
- **LWW comparisons are at millisecond precision** on `client_updated_at` (§9.3).

### 4.4 Import/export JSON

The export document (§8.16) is a shared interchange format across all clients. Same field names (camelCase Task shape), same lenient-import rules.

### 4.5 Auth providers

The backend has **Google, GitHub, and Sign in with Apple** OAuth providers configured. Android must offer **all three** — an iOS-first user whose PocketBase account is keyed to their Apple identity must be able to reach the same data from Android. All three run through the same PocketBase web-redirect OAuth flow (§10); no Play-services-specific sign-in path.

### 4.6 MCP server coexistence

The MCP server (Claude Desktop) reads/writes the same backend with ~20 tools (list/create/update/complete/delete/bulk-update tasks, analytics queries). It needs nothing from Android except wire-schema fidelity. Tasks created on Android appear to Claude Desktop and vice versa, mediated purely by sync.

### 4.7 Device-local fields

`notificationSent`, `lastNotificationAt`, and `snoozedUntil` are **device-local**: they are pushed on the wire but **never taken from the remote on pull/merge** — each device manages its own reminder state (§9.4). Preserving this rule is what keeps a snooze on the phone from silencing a reminder on the tablet, and vice versa.

---

## 5. Design System

GSD's brand is **Editorial · Calm · Focused** — magazine-like restraint, a serif display face, and color rationed to the four quadrant accents. Everything below was extracted from the shipped iOS app and web brand; hex values are authoritative. The Android app expresses this through restyled Material 3 components: **no dynamic color, no tonal-elevation tinting, no Material baseline purple anywhere.**

**Anti-references** (what GSD must never look like): dense corporate-SaaS control panels; neon/glassy/gradient-heavy "productivity" aesthetics; playful/cartoonish; gamified streak-driven dopamine loops.

### 5.1 Color — quadrant accents (the only strong color in the app)

| Quadrant | Name | Light | Dark |
|---|---|---|---|
| Q1 `urgent-important` — **Do First** | Rust | `#B23A2E` | `#E0705F` |
| Q2 `not-urgent-important` — **Schedule** | Tide | `#2C6680` | `#6FAACB` |
| Q3 `urgent-not-important` — **Delegate** | Ochre | `#8A6A22` | `#CFB266` |
| Q4 `not-urgent-not-important` — **Eliminate** | Slate | `#6F685F` | `#A9A096` |

**Quadrant washes** — hand-tuned opaque tints (NOT alpha-derived), used behind tag chips and the selected cell of the editor's 2×2 quadrant picker:

| Quadrant | Wash light | Wash dark |
|---|---|---|
| Q1 Rust | `#F4E4E0` | `#3A211D` |
| Q2 Tide | `#E1ECF1` | `#173039` |
| Q3 Ochre | `#F0E9D8` | `#322B17` |
| Q4 Slate | `#ECE9E3` | `#2A2620` |

The one place accent **alpha** is used: the editor 2×2 picker's unselected cell border = accent at 35% opacity (selected = accent at 100% + wash fill).

### 5.2 Color — the "warm paper" neutral ramp

| Token | Purpose | Light | Dark |
|---|---|---|---|
| `paper` | page background | `#F4F1E9` | `#17150F` |
| `sunken` | inset fills, progress tracks, resting chips | `#ECE7DC` | `#100E0A` |
| `surface` | raised cards, sheets, capture bar | `#FFFFFF` | `#221E17` |
| `surface2` | secondary surface, circular buttons | `#FBF9F3` | `#1B1812` |
| `hairline` | separators, card borders | `#E3DDD0` | `#322D24` |
| `hairlineStrong` | stronger borders, unselected rings | `#D8D1C1` | `#423B2F` |
| `ink` | primary text | `#211E1A` | `#F1ECE2` |
| `ink2` | secondary text | `#6E6760` | `#A79F92` |
| `ink3` | tertiary text, quiet icons | `#797368` | `#948A79` |
| `inkOnAccent` | glyph on a filled accent | `#FFFFFF` | `#17150F` |
| `shadow` | warm-tinted card shadow ink | `#282116` | `#000000` |

### 5.3 Color — functional

| Token | Purpose | Light | Dark |
|---|---|---|---|
| `success` | completion, 100% progress | `#3E7D52` | `#6FB07F` |
| `alert` | overdue, delete, destructive | `#B23A2E` | `#E0705F` |
| `alertWash` | field behind alert text | `#F4E4E0` | `#3A211D` |
| `tint` | the single interactive tint (links, actions) = Tide | `#2C6680` | `#6FAACB` |

Sync-status semantics: error = `alert`; soft health warning = **Ochre** ("attention, not alarm"); pending/progress = default ink.

**Material 3 `ColorScheme` mapping** (so stock components inherit correctly): `primary = tint`, `background = paper`, `surface = surface`, `surfaceVariant = sunken`, `outline = hairlineStrong`, `outlineVariant = hairline`, `error = alert`, `onBackground/onSurface = ink`, `onSurfaceVariant = ink2`, `onPrimary = inkOnAccent`. Set **tonal elevation to 0** everywhere (no elevation tinting) and expose the full GSD token set via a `CompositionLocal` alongside `MaterialTheme`.

Theme preference: **System / Light / Dark** (user-selectable in Settings; follows system by default).

### 5.4 Typography

Exactly **two typefaces**:

- **Newsreader** (serif; bundled — it's the web app's display face, free on Google Fonts, SIL OFL; its own fallback chain is "New York"/Georgia, which is what iOS uses). Display roles only. Use the variable font; weights regular–semibold.
- **System sans (Roboto / OEM default)** for everything functional. **Never body copy in serif.**
- Monospace (system mono) appears only when rendering the capture shorthand tokens themselves (onboarding, help: `!!`, `*`, `#tag`).

| Role | Face | Size / weight | Used for |
|---|---|---|---|
| Large Title | Newsreader | 34sp / semibold | top-app-bar expanded titles |
| Title | Newsreader | 28sp / semibold | sheet titles ("New Task"), onboarding |
| Quadrant Title | Newsreader | 20sp / semibold | quadrant headers (in the quadrant pigment), empty-state headlines |
| Card title | Sans | 17sp / semibold | task titles |
| Body | Sans | 17sp / regular | editor fields, body copy |
| Subhead | Sans | 15sp / regular | card description preview |
| Metadata | Sans | 13sp / regular | card meta row, tag chips |
| Caption | Sans | 12sp / regular, caps | section labels |

Dashboard stat numerals are Newsreader. Use `sp` everywhere (respect user font scale; test at 2× / non-linear scaling). Tabular (monospaced) digits for counts, timers, and subtask progress. Card title wraps to 2 lines (unlimited at accessibility scales); description 2 lines; metadata row 1 line.

Brand lockup in the top app bar: 24dp app mark + "GSD" (sans, bold, ink) + "·" (ink3) + screen name (sans, semibold, ink2).

### 5.5 Shape & spacing

Corner radii (all continuous/squircle-feeling; Compose `RoundedCornerShape` is fine):

- `tile` = 8dp (small tiles, capture-token chips) · `small` = 12dp · `input` = 16dp (text inputs, stat cards) · `card` = 22dp (cards, grouped panels) · `sheet` = 26dp (bottom sheets)
- Chips, buttons, and the capture bar are **full pills** (capsule).
- Card accent spine: 3dp wide, 1.5dp corner radius. Progress tracks: capsule.

Spacing is a strict **4dp grid**: 4 hairline gaps · 8 chip padding · 12 in-card rhythm · 16 card padding · 20 screen inset · 24 section gap · **32 between quadrants**. Board panels (2×2 grid) gap at 16.

**Hit targets ≥ 48dp** (Android's floor; iOS used 44pt — go with the platform's stricter 48).

**Cards:** `surface` fill + 1dp `hairline` border + one soft shadow (`shadow` at 10% opacity, ~10dp blur, y-offset 4dp). Borders do the heavy lifting; no glassmorphism, no glow, no tonal tinting.

### 5.6 Task card anatomy

Row layout (top-aligned, 12dp gap), left → right:

1. **Accent spine** — 3dp-wide rounded bar in the quadrant accent. This is how a task wears its quadrant.
2. **Content column** (6dp vertical rhythm):
   - **Title** — card-title style, `ink`; completed = `ink3` + strikethrough.
   - **Description preview** — subhead, `ink2` (2 lines, `ink3` when completed or a bare URL).
   - **Tag chips** — `#tag` capsules: quadrant **wash** background + quadrant **accent** text.
   - **Metadata row** — 13sp, `ink3`, single line: due date (calendar icon; *today* = Tide semibold; *overdue* = `alert` + warning icon) · recurrence repeat icon · blocked (`lock` + count, ink2) · blocking (`arrow-circle` + count) · running timer (pulsing dot + live `HH:MM:SS`) or tracked total (`clock` + `Xh Ym`) · snoozed (`bedtime` icon + remaining).
   - **Subtask progress** — 84×6dp capsule track (`sunken`) with accent fill (`success` green at 100%) + `done/total` label.
3. **Trailing controls:** overflow menu (`⋯`, ink3, ≥48dp target) + the **completion disc** — 28dp circle in a 48dp target; incomplete = 2dp `ink3` ring; complete = accent-filled + `inkOnAccent` check. Tapping the disc toggles completion (never opens the editor).

Blocked tasks show the lock badge but are **not** dimmed (an earlier whole-card dim was removed as too punishing). Completed tasks sort below incomplete within a quadrant and render dimmed/struck.

### 5.7 Iconography

Use **Material Symbols** (outlined style, consistent weight) as the nearest equivalents of the iOS SF Symbols. Canonical concept → icon mapping:

| Concept | Material Symbol |
|---|---|
| Q1 Do First | `local_fire_department` |
| Q2 Schedule | `calendar_month` |
| Q3 Delegate | `group` |
| Q4 Eliminate | `delete` |
| Recurrence | `repeat` |
| Overdue | `warning` |
| Due date | `event` |
| Blocked by | `lock` |
| Blocking | `arrow_circle_right` |
| Tracked time | `schedule` |
| Snoozed | `bedtime` |
| Complete/check | `check` / `check_circle` |
| Overflow | `more_horiz` |
| Matrix (nav) | `grid_view` |
| Browse (nav) | `filter_list` |
| Dashboard (nav) | `bar_chart` |
| Settings (nav) | `settings` |
| Archive | `inventory_2` |
| Search | `search` |
| Sync progress | `sync` |
| Sync problem | `sync_problem` |
| Pin / Unpin | `keep` / `keep_off` |
| Edit | `edit` |
| Share | `share` |
| Duplicate | `content_copy` |
| Undo | `undo` |
| Account | `account_circle` |

Built-in smart-view icons: Today's Focus `target`-style crosshair (`adjust`), This Week `calendar_month`, Overdue Backlog `warning`, No Deadline `event_busy`, Recently Added `auto_awesome`, This Week's Wins `verified`, All Completed `check_circle`, Recurring `repeat`, Ready to Work `bolt`. Smart-view icons render in `ink2` graphite by default; only views with quadrant meaning take color (Today's Focus = Rust, This Week & Ready to Work = Tide, Overdue = `alert`, This Week's Wins = Ochre).

### 5.8 Motion & haptics

Motion is intentional and sparse; **all non-essential animation is suppressed when the system reports animations disabled** (animator duration scale 0 / "Remove animations" accessibility setting — check `ValueAnimator.areAnimatorsEnabled()`).

- **Confetti on completion** — the one celebration. Parameters (feel reference from iOS): **160 particles**, 1.6s duration, gravity 700, launch speed 150–460 with an upward bias (−220 vertical offset), particle size 5–10dp, opacity fading 1→0, origin around the card/center (normalized x 0.3–0.7). **Colors: the four quadrant pigments + success green** — never generic rainbow. Draw on a Compose `Canvas` driven by a frame clock; skip entirely under reduced motion.
- **Running-timer dot:** 7dp dot pulsing opacity 1↔0.35, ~0.85s ease-in-out, repeating; static under reduced motion.
- **Count changes** roll numerically (Compose `AnimatedContent`-style numeric transition) on quadrant headers.
- **Snackbars/toasts** slide+fade from bottom (fade-only under reduced motion). Sheet expansions and list reorders use default snappy springs.
- **Haptics:** exactly one — a success haptic (`HapticFeedbackConstants.CONFIRM`) on complete/uncomplete. Resist adding more.

### 5.9 App icon & brand mark

The brand mark is a **2×2 grid of four rounded pigment tiles with a white checkmark on the top-left (Rust) tile** — no letterforms, no gradients.

- **Adaptive icon:** foreground layer = the four-tile cluster + check (tile corner radius ≈ 23% of tile side; 2×2 with a gutter ≈ 10% of tile side; check stroke ≈ 14% of tile side, round caps, path rising left-to-right); background layer = paper `#F4F1E9`. Keep the cluster inside the adaptive-icon safe zone (66dp of 108dp canvas).
- **Monochrome layer** (themed icons, Android 13+): the single-color mark (tiles + check as silhouette). This is expected launcher citizenship, not dynamic-color adoption.
- Tile pigments (light values): TL Rust `#B23A2E` · TR Tide `#2C6680` · BL Ochre `#8A6A22` · BR Slate `#6F685F`.
- **Splash screen** (Android 12+ SplashScreen API): the mark on `paper` (`#F4F1E9` light / `#17150F` dark).
- In-app 24dp mark: same art, transparent background (used in the top-app-bar lockup).

### 5.10 Key component looks

- **Capture bar:** a pinned pill — `surface` fill, `hairline` border, the soft card shadow — sitting on `paper`. Placeholder: `Capture a task…  (!!  *  #tag)` in `ink3`. Trailing **quadrant chip** (see §8.2). Parsed `#tag` chips appear beneath in neutral `sunken`/`ink2` (they only take quadrant color once on a card). A quiet "Details" text button in `tint` opens the full editor.
- **Quadrant header:** a fixed 26dp icon column (shared left edge) with the accent-colored quadrant symbol, the serif 20sp title in the pigment, and a trailing live active-count in monospaced digits (`ink2`).
- **Empty states:** 60dp `sunken` rounded tile + 28dp icon (`ink3`; tinted only to reassure — e.g. green check for "Nothing overdue"), serif headline, one `ink2` sentence (max width ~280dp), at most one `tint` action. In-context quadrant empties use a dashed `hairlineStrong` border (dash 5), radius 22dp, with tailored copy: Q1 *"No fires right now."* · Q2 *"Nothing scheduled yet."* · Q3 *"Nothing to hand off."* · Q4 *"Nothing to drop."*
- **Sync status chip:** quiet-until-it-matters — **hidden entirely** when idle, healthy, and nothing pending; spinner while syncing (static sync glyph under reduced motion); pending count with sync glyph; `sync_problem` in `alert` on error, in Ochre for soft health warnings.
- **Onboarding:** 4 paged, skippable, editorial screens on `paper` (§8.19).

---

## 6. Information Architecture & Navigation

The app adapts by **window size class**, the Android analog of the iPhone/iPad split.

### 6.1 Compact width (phones)

A **bottom navigation bar** with four destinations:

1. **Matrix** — the primary surface: a pinned **capture bar** at top, then the four quadrants as a **vertical stack of quadrant sections** (each a header with live count + its task rows; four quadrants can't be shown legibly at once on a phone). Pull-to-refresh triggers a manual sync when signed in. Top app bar: brand lockup, search/palette button, show-completed toggle, select-mode toggle, sync status chip.
2. **Browse** — an **Archive** row at top, then Smart Views in sections: **Pinned**, **Built-in**, **Custom**, plus a "+" to create a custom view. Each row shows a live match count. Row swipes: pin/unpin (leading); edit/delete (trailing, custom views only).
3. **Dashboard** — analytics (§8.15).
4. **Settings** — §8.17.

Archive is deliberately *inside* Browse, not a fifth destination.

### 6.2 Medium & expanded width (tablets, unfolded foldables, freeform windows)

- **Medium:** a **navigation rail** (Matrix, Browse, Dashboard, Settings) with phone-style content.
- **Expanded:** a **permanent navigation drawer** mirroring the iPad sidebar — Matrix; Dashboard; a **Smart Views** section (pinned first, then built-ins, then custom, then "New Smart View"); a **Library** section (Archive, Settings) — beside a detail pane. **Matrix at expanded width is a true 2×2 grid** (Q1 top-left, Q2 top-right, Q3 bottom-left, Q4 bottom-right), each cell a header + scrollable list, with **drag-and-drop of task cards across quadrant boundaries** to reclassify (updates `urgent`/`important`). Smart-view rows show live counts; row context menu offers Pin/Unpin (+ Edit/Delete for custom).

### 6.3 Editor presentation

- **Compact:** a **modal bottom sheet** opening half-expanded with the essential fields and a "Show all details" affordance that expands it fully.
- **Medium/expanded:** a centered dialog sheet (the board stays visible behind it).

### 6.4 Deep links

Register the **`gsd://` scheme** (intent filters on the main activity). Routes — identical to iOS so widgets, shortcuts, and notifications share one router:

| URL | Opens |
|---|---|
| `gsd://capture` | Matrix with the new-task editor open |
| `gsd://focus` | Matrix (Q1 focus) |
| `gsd://quadrant/<quadrant-id>` | Matrix scrolled to that quadrant (ids from §7.8) |
| `gsd://task/<id>` | that task's editor (fetch directly from the store; cold-start safe) |
| `gsd://smart-view/<id>` | that smart view's filtered list |
| `gsd://dashboard` · `gsd://settings` · `gsd://archive` | those surfaces |
| `gsd://oauth-callback?...` | reserved for the OAuth flow (§10); the router ignores it |

A deep link arriving before the UI is ready is persisted and consumed on first composition (cold-start). A `task/<id>` link to a task that no longer exists shows a friendly "not found" state, never a blank screen.

### 6.5 App shortcuts (launcher long-press)

Two static shortcuts: **"New Task"** → `gsd://capture` and **"Today's Focus"** → `gsd://smart-view/today-focus`.

### 6.6 Hardware keyboard shortcuts

For tablets/DeX/Chromebooks: **Ctrl+K** command palette · **Ctrl+N** new task · **Ctrl+F** search (palette) · **Ctrl+1–4** jump to quadrant. Escape dismisses sheets.

### 6.7 State & system behavior

- Persist (DataStore, mirroring iOS `@AppStorage`): `showCompleted`, theme preference, `hasOnboarded`, `fetchShareTitles`, plus the pending deep link. Tab/drawer selection and scroll positions are **not** persisted across process death (parity with shipped iOS; standard Compose saved-instance-state within a session is fine).
- **Predictive back** enabled; **edge-to-edge** rendering with proper inset handling.
- First run shows the onboarding flow (§8.19), skippable, gated on `hasOnboarded`.

---

## 7. Data Model

All entities must be representable in the Room store, in the JSON import/export format (§8.16), and (for the syncable subset) in the PocketBase collection (§9.1).

### 7.1 IDs (authoritative)

- Alphabet (64 URL-safe chars): `0-9 A-Z a-z - _` (nanoid's URL-safe set). Uniform-random selection.
- Lengths: **tasks & subtasks 21** (the web canonical), **time entries 8**, **smart views 12**. Minimum accepted anywhere: **4** (IDs are opaque join keys; other clients emit varying lengths and all must round-trip).
- Built-in smart views use fixed readable IDs (§8.13). IDs are generated client-side, once, and never changed.

### 7.2 Task (the core entity)

| Field | Type | Required | Default | Constraints / Notes |
|---|---|---|---|---|
| `id` | String | yes | generated | ≥ 4 chars, unique, URL-safe |
| `title` | String | yes | — | 1–80 chars |
| `description` | String | no | `""` | 0–600 chars |
| `urgent` | Bool | yes | — | one axis of the matrix |
| `important` | Bool | yes | — | the other axis |
| `quadrant` | enum | derived | — | **pure function** of the two flags (§7.8); persisted as an indexed column, **never encoded in domain/export JSON** |
| `completed` | Bool | yes | `false` | |
| `completedAt` | Date? | no | — | set on complete; cleared on un-complete |
| `createdAt` | Date | yes | now | |
| `updatedAt` | Date | yes | now | bumped on every mutation **by the store** (injected clock); drives sync LWW |
| `dueDate` | Date? | no | — | |
| `recurrence` | enum | yes | `none` | `none` / `daily` / `weekly` / `monthly` — **no "yearly"** |
| `tags` | [String] | yes | `[]` | 0–20 items; each 1–30 chars; stored lowercase |
| `subtasks` | [Subtask] | yes | `[]` | 0–50 items |
| `dependencies` | [String] | yes | `[]` | 0–50 task IDs that must complete first |
| `parentTaskId` | String? | no | — | recurring-instance lineage. **Device-local: has no wire column, never synced.** |
| `notifyBefore` | Int? | no | — | minutes before `dueDate`; ≥ 0 (0 = "at time of event") |
| `notificationEnabled` | Bool | yes | `true` | per-task reminder switch |
| `notificationSent` | Bool | yes | `false` | **device-local** (§4.7) |
| `lastNotificationAt` | Date? | no | — | **device-local** |
| `snoozedUntil` | Date? | no | — | **device-local**; reminders suppressed until then; max 365 days out |
| `estimatedMinutes` | Int? | no | — | 1–10080 (7 days); a stored/received `0` means "unset" |
| `timeSpent` | Int? | no | — | total tracked whole minutes, **calculated** from `timeEntries` |
| `timeEntries` | [TimeEntry] | yes | `[]` | 0–1000 items |

**Subtask:** `{ id, title (1–100 chars), completed }`.
**TimeEntry (rich local form):** `{ id, startedAt, endedAt? (nil while running), notes? (0–200 chars) }`. The wire form is a lossy `{id, startedAt, minutes}` (§9.2).

### 7.3 JSON encoding rules (domain / export / store)

- camelCase keys; **`quadrant` is never encoded** (always recomputed from the flags).
- Dates: ISO-8601 UTC with **millisecond precision**, `T` separator, `Z` suffix (`2026-06-15T08:30:00.500Z`).
- `null` optionals are **omitted**, not written as `null`. Empty strings encode as `""`, empty arrays as `[]`.
- **Decoding is lenient:** required fields are only `id, title, urgent, important, createdAt, updatedAt`; everything else defaults (`description ""`, `completed false`, `recurrence none`, collections `[]`, `notificationEnabled true`, `notificationSent false`). Unknown keys are ignored (old exports may contain e.g. `vectorClock`). A task failing required-field decode or validation is skipped and counted, never aborts the batch.

### 7.4 NotificationSettings (singleton)

`enabled` (default true) · `defaultReminder` minutes (default **15**; presets 15/30/60/120/1440) · `soundEnabled` (default true) · `quietHoursStart`/`quietHoursEnd` (`"HH:mm"` local; UI default 22:00–07:00 when enabled) · `permissionAsked` (default false) · `updatedAt`.

### 7.5 ArchiveSettings (singleton)

`enabled` (default **false**) · `archiveAfterDays` ∈ {**30, 60, 90**} (default 30).

### 7.6 SmartView

`id` (built-ins fixed; custom 12-char nanoid) · `name` (1–60 chars) · `icon` (icon token; custom views choose from 10 curated icons) · `criteria` (FilterCriteria, §7.9) · `isBuiltIn` (read-only when true) · `createdAt` · `updatedAt`.

### 7.7 AppPreferences (singleton) + lightweight prefs

`pinnedSmartViewIds` ([String], ordered, max **5**). Preference storage (DataStore): `showCompleted`, theme (`system`/`light`/`dark`), `hasOnboarded`, `fetchShareTitles` (default false).

### 7.8 Quadrant derivation (authoritative)

| `urgent` | `important` | quadrant id | Title | Intent | Accent |
|---|---|---|---|---|---|
| true | true | `urgent-important` | **Do First** (Q1) | crises, deadlines | Rust |
| false | true | `not-urgent-important` | **Schedule** (Q2) | growth, planning | Tide |
| true | false | `urgent-not-important` | **Delegate** (Q3) | interruptions | Ochre |
| false | false | `not-urgent-not-important` | **Eliminate** (Q4) | distractions | Slate |

Canonical display/iteration order: Q1, Q2, Q3, Q4. Never let the persisted quadrant drift from the flags.

### 7.9 FilterCriteria (powers smart views, filters, search)

A predicate bundle; all present criteria are **ANDed**. camelCase-Codable:

| Field | Type | Meaning |
|---|---|---|
| `quadrants` | [quadrant-id] | include only these (empty = all) |
| `status` | `all` \| `active` \| `completed` | |
| `tags` | [String] | task must contain **all** listed tags |
| `dueDateRange` | { start?, end? } | inclusive bounds |
| `overdue` | Bool | incomplete AND `dueDate` < today |
| `dueToday` | Bool | incomplete AND due today |
| `dueThisWeek` | Bool | incomplete AND due in [today, today+7) |
| `noDueDate` | Bool | no `dueDate` |
| `recurrence` | [recurrence] | include only these kinds |
| `recentlyAdded` | Bool | `createdAt` within last 7 days |
| `recentlyCompleted` | Bool | completed AND `completedAt` within last 7 days |
| `readyToWork` | Bool | incomplete AND no incomplete blocking dependency |
| `searchQuery` | String | case-insensitive substring across title, description, tags, **and subtask titles** |

`readyToWork` needs the full task set (to resolve blocker completion).

### 7.10 Room tables

Mirror the separation used by both sibling clients (Dexie schema v14 / GRDB v1–v5): **`tasks`**, **`archivedTasks`** (same shape + `archivedAt`, a separate table), **`smartViews`**, **`notificationSettings`**, **`archiveSettings`**, **`appPreferences`**, **`syncQueue`** (§9.5), **`syncMetadata`** (cursor + device identity), **`syncHistory`** (§9.7). Collections (`tags`, `subtasks`, `dependencies`, `timeEntries`) are **JSON TEXT columns** (§7.3 encoding), not child tables — matching Dexie/PocketBase/GRDB shapes. Index `quadrant`, `completed`, `updatedAt`, `dueDate`. Versioned Room migrations from day one; a row with an unrecognized enum degrades gracefully (`recurrence` → `none`) rather than failing the fetch.

### 7.11 Validation

Applied on **every write path and on import** (`TaskValidator` equivalent): the §7.2 limits; tags trimmed, lowercased, deduplicated, empty dropped; estimate 0 coerced to unset; snooze capped at 365 days. Validation failures are typed errors surfaced as human copy, never silent truncation (except explicitly clamped share-capture input, §12.2).

---

## 8. Feature Specifications

Each feature lists **Behavior** (the rule — shared across all GSD clients, authoritative) and **Android reimagining** (how it should feel). Where the original iOS spec and the shipped app diverged, this section reflects the shipped app.

### 8.1 The Matrix

**Behavior.** Tasks group into the four quadrants (§7.8). Within a quadrant, incomplete tasks sort above completed; completed tasks render dimmed with strikethrough. A global **show-completed** toggle hides/reveals completed tasks. Quadrant headers show live active counts.

**Android reimagining.**
- **Compact:** vertical stack of quadrant sections (§6.1). Reclassify via the row menu ("Move to…") — no cross-quadrant drag in a single column.
- **Expanded:** true 2×2 grid; **drag a card across quadrant boundaries** to reclassify.
- **Row interactions (both):**
  - **Swipe right (leading)** → complete/uncomplete (full-swipe commits), with the success haptic + confetti on complete.
  - **Swipe left (trailing)** → reveal **Snooze** (quick-snooze **1 hour**) and **Delete**.
  - **Tap** → open editor. **Tap the completion disc** → toggle complete (never opens the editor).
  - **Long-press** → context menu: Edit, Complete/Uncomplete, Start/Stop timer, Snooze (submenu of the six presets), Duplicate (a fresh copy with new IDs for the task and its subtasks, incomplete, no time entries), Share, Move to quadrant, Delete.
- **Multi-select:** a select mode (toolbar toggle or long-press-drag) with checkmarks and the bulk-action bar (§8.11).
- **Empty quadrants** show the dashed in-context prompt with tailored copy (§5.10) and an "add to this quadrant" affordance. A fully empty matrix shows "Capture your first task" with an example.
- Lists must stay smooth with **hundreds of tasks** (`LazyColumn` keys + stable item contents).

Task card contents: §5.6 — title, description preview with tappable links, tag chips, subtask progress, blocked/blocking badges, relative due date ("in 3 days", "Due today" in Tide, overdue in alert), recurrence glyph, live timer/tracked time, snooze remaining.

### 8.2 Quick capture + the shorthand parser

**Behavior — parser grammar (authoritative, security-relevant):** a single text field accepts a title with inline shorthand parsed on submit:

| Token | Effect | Notes |
|---|---|---|
| `!!` | `urgent = true` AND `important = true` | word boundaries; takes precedence over `!` |
| `!` | `urgent = true` | word boundaries |
| `*` | `important = true` | word boundaries |
| `#tag` | adds `tag` (lowercased) | deduplicated; capped at 20 |
| `http(s)://…` URL | **moved from title to description** | sanitized (below) |

After parsing, the cleaned title has tokens/URLs removed and whitespace collapsed. No flags → the task lands in **Eliminate (Q4)** unless a manual quadrant override is set.

**URL sanitization (replicate exactly):** accept only `http`/`https`; reject embedded credentials (`user:pass@`); require a valid hostname; reject URLs ≥ 2048 chars; strip trailing sentence punctuation (`, ; : . ! ? )`). Valid URLs append to the description on their own lines (newline-separated from existing text). If removing URLs empties the title but ≥1 URL was found, title becomes **"Review link below"**. Invalid/unsafe URLs stay in the title untouched.

**Android reimagining.**
- The capture bar (§5.10) shows a **live preview**: the trailing **quadrant chip** rests as "**Auto**" (neutral grid glyph) and switches to the live quadrant name + symbol in its pigment as `!`/`*` are typed; tapping it cycles the manual override `Auto → Q1 → Q2 → Q3 → Q4 → Auto` (Tab cycles it on hardware keyboards). Detected `#tags` render as chips beneath.
- **Submit** (IME action) adds the task and keeps focus for rapid serial capture. Validation failure restores the raw text inline.
- **"Details"** opens the full editor pre-filled from the parsed draft (consuming it).
- Capture is also reachable from the share target (§12.2), the app shortcut, and the widget's deep link.

### 8.3 Task editor

**Behavior.** Full create/edit surface for every field; save validates §7.2 limits; save disabled while the title is empty. Editing `dueDate` or `notifyBefore` **resets reminder state** (`notificationSent = false`, clears `lastNotificationAt` and `snoozedUntil`) so the user gets re-notified.

**Android reimagining** — sections in order:
- **Title** (multiline-capable field).
- **Quadrant** — a 2×2 picker mirroring the matrix: each cell titled + accent-colored; selected = accent border + wash fill; unselected = accent border at 35% opacity.
- **Tags** — chip field: type + comma/enter commits; chips have ≥48dp remove targets; autocomplete from existing tags.
- **Notes** (description).
- **Links** — read-only tappable list auto-detected (http/https) from the notes.
- **Due date** — toggle + date picker + preset chips (§8.10).
- **Reminder** — visible only when a due date is set: **None / At time of event / 5 / 15 / 30 minutes / 1 / 2 hours / 1 day before** (defaults to the global default reminder).
- **Repeat** — Never / Daily / Weekly / Monthly.
- **Subtasks** — inline checklist: add, toggle, drag-reorder, swipe-delete.
- **Estimate** — minutes field (1–10080) + "Tracked *Xm* of *Ym*" readout; over-estimate renders in `alert`.
- **Snooze** — menu of the six presets + clear (shows current snooze state).
- **Dependencies** — searchable task picker that runs the cycle check live (§8.8), disabling choices that would create a cycle, with an explanation; lists current blockers/blocked.
- New tasks reserve their ID at editor-open (so dependency edges made during creation are stable). Cancel/back discards with the standard predictive-back treatment.

### 8.4 Completion (+ celebration)

**Behavior.** Complete sets `completed = true`, `completedAt = now`; un-complete clears `completedAt`. Completing a **recurring** task also spawns the next instance (§8.5).

**Android reimagining.** Complete via leading swipe, disc tap, context menu, notification action (§11.4), or bulk bar — always with the success haptic and **confetti** (§5.8, suppressed under reduced motion). The card animates to its dimmed/sorted position.

### 8.5 Recurrence engine

**Behavior (authoritative).** `recurrence ∈ {none, daily, weekly, monthly}`. When a recurring task is completed, immediately create a **new task instance**:
- New `id`, `createdAt`, `updatedAt`; `completed = false`.
- `parentTaskId` = the completed task's `id` — or, if that task was itself an instance, *its* `parentTaskId` (single-level lineage to the original). Lineage is device-local (§7.2).
- `dueDate` advanced from the **prior due date**: daily +1 day; weekly +7 days; monthly +1 calendar month with month-end clamping (Jan 31 → Feb 28/29). No due date → the instance has none.
- **All subtasks reset to incomplete.** Reminder state reset (`notificationSent = false`; `lastNotificationAt`, `snoozedUntil` cleared).
- The completed original remains as history; the new instance carries the recurrence forward. Schedule the instance's reminder at spawn time.

### 8.6 Subtasks

Up to 50 per task; title 1–100 chars; add/toggle/delete/reorder in the editor. Cards show read-only progress (`done/total` + bar; 100% = success green). Recurring completion resets them.

### 8.7 Snooze

**Behavior.** Snoozing sets `snoozedUntil = now + duration`; reminders are suppressed while snoozed and the card shows remaining time. Presets (authoritative): **15 minutes, 30 minutes, 1 hour, 3 hours, Tomorrow (+1 day), Next week (+7 days)**; max 1 year. Quick-snooze from swipe = **1 hour**. `snoozedUntil` is device-local.

**Android reimagining.** Snooze from trailing swipe (1 hour), the context-menu preset submenu, the editor, or the reminder notification's Snooze action; reschedule the alarm accordingly (§11).

### 8.8 Dependencies (blocking graph)

**Behavior (authoritative).** Up to 50 dependency IDs per task. **Cycle prevention via BFS:** before adding `B` as a dependency of `A`, walk from `B` over the dependency graph; if `A` is reachable, reject. Self-reference always rejected; every dependency ID must exist. Queries: blocking tasks, uncompleted blockers, isBlocked, blocked tasks (reverse), ready tasks (incomplete with no uncompleted blockers — powers "Ready to Work"). **On task delete, remove its ID from every other task's `dependencies` first.**

**Android reimagining.** Cards surface "Blocked by N" (lock) / "Blocking N" badges; tapping reveals the related tasks. Blocked tasks are excluded from Ready to Work but **not** visually dimmed.

### 8.9 Time tracking

**Behavior.** **Start** creates `{id, startedAt: now}`; only **one running entry per task** (second start rejected). **Stop** sets `endedAt = now` and recalculates `timeSpent` = Σ floor((endedAt − startedAt)/60) whole minutes over completed entries. Formatting: `< 1m` → "< 1m"; under an hour → "Xm"; else "Xh Ym" ("Xh" when no remainder).

**Android reimagining.** Start/Stop from the context menu and editor; a running task's card shows the pulsing dot + live `HH:MM:SS` (ticking once per second, only while visible). No foreground service, no Live-Activity analog — the timer is data, not a process.

### 8.10 Due dates & presets

**Behavior (authoritative).** Presets resolve in the device's local time zone: **None** → unset; **Today** → today; **This week** → the **Friday of the current week** (Saturday/Sunday → *next* Friday); **Next week** → the **Monday of next week** (strictly after today).

**Android reimagining.** Preset chips + a Material date picker; cards show relative formatting ("in 3 days", "Due today" emphasized in Tide, overdue in alert).

### 8.11 Bulk actions (multi-select)

**Behavior.** Operations (authoritative): **complete**, **move to quadrant**, **add tags**, **remove tags**, **set due date**, **delete** — each applies per-task validation, enqueues sync per task, and reports partial failures. Delete confirms first. The Archive screen's bulk bar offers **restore** and **delete permanently** (confirmed: "This can't be undone.").

**Android reimagining.** Select mode on matrix (compact + grid), smart-view lists, and archive: checkmarks, a selection count, and a **bottom action bar**. Undo (snackbar) follows destructive actions where applicable (§8.20).

### 8.12 Archive

**Behavior.** Completed tasks can move to the separate archive store (full task shape + `archivedAt`). **Manual:** archive a completed task; restore to active; delete permanently. **Auto:** when enabled, completed tasks with `completedAt` older than `archiveAfterDays` (30/60/90) move automatically — swept on launch and by the periodic maintenance job. **Archive transitions sync as active-record transitions:** archiving enqueues a *delete* of the remote active record; restoring enqueues a *create/update*. Archived tasks themselves never sync (§9.4's reconcile ignores the archive table).

**Android reimagining.** Archive screen (Browse → Archive / drawer Library): dimmed (≈72% opacity) read-only cards; swipe to Restore (leading) or Delete-permanently (trailing, confirmed); search field; multi-select bulk bar; a toolbar menu exposing the auto-archive toggle + 30/60/90 picker + "Archive now".

### 8.13 Smart Views & filters

**Behavior.** A SmartView bundles FilterCriteria with a name/icon. **Nine built-ins** ship, read-only, with these exact IDs:

| ID | Name | Criteria |
|---|---|---|
| `today-focus` | Today's Focus | Q1, active |
| `this-week` | This Week | active, due this week |
| `overdue` | Overdue Backlog | active, overdue |
| `no-deadline` | No Deadline | active, no due date |
| `recently-added` | Recently Added | active, created ≤ 7 days ago |
| `weeks-wins` | This Week's Wins | completed, completed ≤ 7 days ago |
| `all-completed` | All Completed | completed, all time |
| `recurring` | Recurring Tasks | active, recurrence ∈ {daily, weekly, monthly} |
| `ready-to-work` | Ready to Work | active, no uncompleted blocker |

Users create/edit/delete **custom** views (name ≤ 60 chars; icon from 10 curated options; the full criteria editor: status segmented control, quadrant multi-select, tags, due-date predicate toggles, date range, recurrence kinds, ready-to-work, search text) and **pin up to 5** views (ordered; pinned surface first everywhere).

**Android reimagining.** Browse tab sections on compact; drawer section on expanded (§6). Each view shows a live count; opening one shows the flat filtered list (§8.1 rows) with `.searchable`-style in-list search layered onto the criteria; view-aware empty states (Overdue → green check "Nothing overdue"; Wins → trophy; search-miss message; generic otherwise).

### 8.14 Search & command palette

**Behavior.** Full-text **case-insensitive substring** search across title, description, tags, and subtask titles, live-updating. The command palette matches both **tasks** and **commands** — substring matching (not fuzzy), sectioned results: **Tasks · Smart Views · Actions · Navigation**. Actions: New task, Toggle show completed, Toggle theme. Navigation: Matrix, Dashboard, Archive, Settings, and each smart view.

**Android reimagining.** Invoked by the toolbar search button on any surface, or Ctrl+K / Ctrl+F on hardware keyboards. Full-screen search surface on compact (keyboard-first); a centered palette dialog on expanded with arrow-key navigation + Enter. Archive keeps its own plain in-list search.

### 8.15 Analytics dashboard

**Behavior (authoritative metric set — computed from the current task set, on demand, off the main thread):**
- **Stat grid:** Active tasks, Completed tasks, Completion rate (completed ÷ total), total Tracked time. **No streaks, no badges — deliberately removed; do not add.**
- **Completion trend:** for the selected window (**7 / 30 / 90** days), per-day counts of tasks *created* vs *completed* (line/area chart).
- **Quadrant distribution:** active-task count per quadrant (donut/bar in the quadrant pigments).
- **Top tags:** per-tag totals (bar).
- **Time by quadrant:** tracked minutes per quadrant.
- **Upcoming deadlines:** next due items (tap → editor). An **overdue banner** (tap → Overdue Backlog view) when overdue > 0.

**Android reimagining.** A stat-card grid (Newsreader numerals) + charts drawn in Compose (Canvas or a light chart lib) using quadrant pigments only; graceful empty state ("No stats yet") when there are no tasks.

### 8.16 Import / export, erase

**Export.** JSON envelope `{ "tasks": [ …full camelCase Task records, rich timeEntries… ], "exportedAt": "<ISO-8601 ms>", "version": 1 }`, pretty-printed with **sorted keys** (§7.3 dates). Via the system file-save flow (`ACTION_CREATE_DOCUMENT`) and the share sheet.

**Import.** Accept that JSON leniently (§7.3): limits **10,000 tasks / 10 MB** (byte check first). Per-task lenient decode + validation; invalid tasks skipped and counted, reported as "imported N, skipped M". Two modes, chosen after picking a file (`ACTION_OPEN_DOCUMENT`):
- **Replace** — imported set becomes the store: stamp `updatedAt = now`, enqueue `update` for every imported ID **and `delete` for every existing ID not in the import**, then swap the table atomically.
- **Merge** — insert alongside existing; colliding IDs get regenerated (collision-checked against existing + imported + already-assigned), with `dependencies` **and `parentTaskId`** remapped through the complete ID map (forward references included). Stamp `updatedAt = now`, enqueue `update` per task.

**Erase all data.** A guarded destructive flow: type **"RESET"** to confirm, with an export-first prompt. Clears tasks, archive, custom views, sync queue, pins, archive settings; cancels reminders; **keeps theme + onboarding flags**. If signed in, it erases **everywhere**: all remote records are deleted first (§9.8); only after remote success does the local wipe proceed.

### 8.17 Settings

Sections in order (Material list groups):

1. **Appearance** — Theme (System/Light/Dark); Show Completed Tasks.
2. **Sharing** — "Fetch titles for shared links" (default **off**; footer explains it performs a network fetch).
3. **Account** — signed out: Sign in with Google / Apple / GitHub + a one-line privacy hint; signed in: account email (+ a note when it's an Apple private-relay address), sync status ("Synced · N pending"), health message when unhealthy, **Sync Now**, **Sync History** (screen: totals + the ~50 most recent entries with status/counts/duration), **Sign Out**, **Delete Account…** (§8.21). There is deliberately **no** sync on/off toggle — signing in *is* enabling sync.
4. **Archive** — auto-archive toggle; "Archive after" 30/60/90; **Archive Now** + status line.
5. **Notifications** — Enable Reminders; Default Reminder (15m/30m/1h/2h/1d); Sound; Quiet Hours toggle + from/to pickers (default 22:00–07:00); system-permission status row with a contextual **Enable notifications** / **Open system settings** action.
6. **Data & Storage** — Export (prepare → share/save); Import (file picker → Merge/Replace choice); Erase All Data (§8.16).
7. **About** — version + build; privacy blurb; Privacy Policy → `https://gsdtaskmanager.com/privacy/`; Contact Support → `gsdapp@vinny.dev`; "How to use GSD" (the Field Guide, §8.19); "Show onboarding again".

### 8.18 Task sharing (outbound)

Every card menu and the editor expose **Share**: a plain-text rendering via the system share sheet — line 1 title; line 2 quadrant title; then (if due) a medium-format date; then (if tagged) `#tag #tag …`; then a blank line + the description. No JSON, no links to servers.

### 8.19 Onboarding, Help & About

- **Onboarding:** 4 paged, skippable editorial screens on `paper` — **Welcome** (mark + tagline) → **The Matrix** (axes diagram) → **Capture** (shorthand legend in monospace) → **Privacy & sync** (lock motif; "no account required; your data stays on device"). Final page: "Start using GSD" (primary, ink-filled pill) + "Sign in with Google" / "Sign in with Apple" + a quiet sync hint. Cross-fade instead of slide under reduced motion.
- **Help ("Field Guide"):** a static reference sheet — the board & capture bar; the four quadrants with intent blurbs; quick-add syntax with the example `!! ship the deck #work #q2`; keyboard shortcuts (shown only when a hardware keyboard is relevant); editing/completing/drag; cloud sync (optional); privacy; a link to gsdtaskmanager.com.
- **About:** mark, tagline "Get the right things done.", version, site link, maker's credit.

### 8.20 Undo delete

Deleting a task (swipe, menu, or bulk) **commits immediately** — the row is gone, the sync delete is enqueued (tombstone-safe) — and a **snackbar** appears: `Deleted "<title>"` with **Undo** (~6 s; extended ~12 s when TalkBack is active). Undo **re-creates** the task from a snapshot as a fresh write (new `updatedAt`, LWW-safe against the earlier delete). No blocking confirmation dialogs for single deletes; calm undo instead. Bulk delete and archive-permanent-delete still confirm (irreversible at scale).

### 8.21 Account switching, account deletion, recovery

- **Account switch:** when a sign-in resolves to a **different** account than the last known owner *and* local active tasks exist, prompt: **"Different account"** — *Keep my tasks* (merge: local tasks seed-upload into the new account), *Start fresh (erase tasks on this device)* (destructive), *Cancel* (signs back out). Archived tasks never trigger the prompt (they don't sync).
- **Delete account:** confirmation offering *Delete & keep tasks on this device* or *Delete & erase everything* (+ Cancel), warning it's permanent and removes every synced task. Order matters: erase remote records first, then delete the user record (`DELETE /api/collections/users/records/{id}`), then clear the token.
- **Database-unavailable recovery:** if the local DB cannot open even after recovery attempts, show a calm full-screen fallback — "Couldn't open your tasks", reassurance (data not deleted; restart; free storage), Contact Support — and **never** start sync or observation against a broken store.

---

## 9. Sync & Backend

Sync is **optional and opt-in**. With no account the app is fully functional offline and nothing leaves the device. Signed in, tasks sync bidirectionally with the self-hosted **PocketBase** at **`https://api.vinny.io`**, shared with the web app, the iOS app, and the MCP server.

> Build a minimal PocketBase client (REST + SSE) — treat it as net-new, higher-risk code with its own recorded-fixture test suite. Everything below is the **shipped, live-verified protocol** (it corrects a few details of the original iOS spec; where they differ, this is authoritative).

**Auth header quirk (applies to every authenticated request, including realtime subscribe and auth-refresh):** the header is the **raw JWT** — `Authorization: <token>` with **no `Bearer ` prefix**.

### 9.1 The `tasks` collection (authoritative wire model)

snake_case fields. The collection exists; read/write these exact names:

| Field | Type | Notes |
|---|---|---|
| `id` | string | the PocketBase **record** id (15 chars, server-generated) — distinct from the task's own id. Send `""` (or omit) on create; read the real id from the response and key PATCH/DELETE on it |
| `task_id` | string | the app's Task `id` — the cross-client join key; unique per owner |
| `owner` | string | the authenticated user id (the JWT's `id` claim). Server API rule scopes rows to `owner = @request.auth.id` |
| `title`, `description` | string | |
| `urgent`, `important` | bool | |
| `quadrant` | string | **write** the §7.8 id (`urgent-important` …); **ignore on read** — always recompute from the flags |
| `due_date`, `completed_at`, `last_notification_at`, `snoozed_until` | string | ISO-8601 ms (`T`/`Z`) or `""` for nil |
| `completed` | bool | |
| `recurrence` | string | `none`/`daily`/`weekly`/`monthly` |
| `tags` | json [string] | |
| `subtasks` | json [{id,title,completed}] | |
| `dependencies` | json [string] | |
| `notification_enabled`, `notification_sent` | bool | device-local semantics (§4.7) |
| `notify_before`, `estimated_minutes` | number/null | omit when nil. **PocketBase returns absent numbers as `0`** — treat `estimated_minutes == 0` as unset |
| `time_spent` | number | `timeSpent ?? 0` |
| `time_entries` | json | flattened `{id, startedAt, minutes}` — note `startedAt` stays **camelCase** inside the otherwise snake_case record |
| `client_updated_at` | string | ISO-8601 ms — **the LWW key** |
| `client_created_at` | string | ISO-8601 ms |
| `device_id` | string | originating device, for realtime echo filtering |
| `created`, `updated` | string | PocketBase system autodates, **space-separated** form (`2026-06-10 12:00:00.123Z`). Never encode them on write. `updated` is **the pull cursor** (completeness); it is **never** used for conflict decisions |

**`parentTaskId` has no wire column** — recurrence lineage stays device-local.

Decode defensively: only `task_id` is required; every other field tolerates absent/empty/null. Skip a record with an unparseable `client_updated_at`. Date parsing is lenient (normalize the space separator to `T`; accept whole-second and fractional forms); date *writing* is always fractional-ms `T`/`Z`, and nil dates write `""`.

### 9.2 The task mapper (local ⇄ wire)

**Push (local → wire):** map camelCase → snake_case per the table; `updatedAt → client_updated_at`, `createdAt → client_created_at`; flatten each time entry to `minutes = max(0, floor((endedAt − startedAt)/60))` — a **running** entry (nil `endedAt`) flattens to `minutes = 0`; `notes`/`endedAt` are dropped (the wire form is lossy).

**Pull (wire → local):**
- No local copy → reconstruct everything from the wire; time entries get `endedAt = startedAt + minutes×60`, `notes = nil`; `parentTaskId = nil`.
- Local copy exists (remote won LWW) → remote wins for synced fields, but **preserve from local:** `parentTaskId`, `notificationSent`, `lastNotificationAt`, `snoozedUntil`, **and `timeSpent` + `timeEntries`** (prefer the rich local copy over the lossy wire form).
- `quadrant` is always recomputed from `urgent`/`important`.

### 9.3 Conflict resolution — last-write-wins

Compare `client_updated_at` vs local `updatedAt` as **millisecond integers**: remote newer → take remote; local newer → keep local; **equal or unparseable → no-op** (never overwrite). The same guard protects both directions: on push, a queued item is **skipped** when the remote's `client_updated_at` is newer than the queued payload's `updatedAt` (the next pull delivers the remote version).

### 9.4 Pull, cursor, and deletion reconciliation

- **Endpoint:** `GET /api/collections/tasks/records?page={n}&perPage=200&sort=updated&filter=updated >= "{cursor}"` (filter URL-encoded; page through **all** pages until `page ≥ totalPages`; response envelope `{page, perPage, totalItems, totalPages, items}`). No owner filter is sent — the server's API rule scopes rows.
- **Cursor:** the max applied **server `updated`** stamp, stored in the PocketBase space-separated form; first sync uses `"1970-01-01 00:00:00.000Z"`. After a successful sync, advance to `maxApplied − 5 seconds` (the overlap rewind that catches boundary writes). A record whose `updated` is unparseable still applies but doesn't advance the cursor.
- **Apply loop:** per record — validate; skip malformed (never abort the pull); apply LWW (§9.3); on upsert preserve device-local fields (§9.2). Count remote-won overwrites as `conflictsResolved`.
- **Deletion reconciliation** (runs **last**, after push, destructive): fetch a fresh full remote index (`task_id` set); delete every local **active** task whose id is absent remotely **and** not present in the sync queue (pending **or** failed items both protect). The archive table is never touched. This is safe only because of the **enqueue-before-write invariant**: every local mutation enqueues its sync operation *before* the row becomes visible.

### 9.5 Push & the sync queue

Every local mutation (create/update/delete/archive/restore/import/bulk) enqueues a queue row: `{ id, taskId, operation: create|update|delete, timestamp (ms), retryCount, payload (full Task JSON for create/update; null for delete), status: pending|failed, lastError?, lastAttemptAt?, failedAt? }`.

Push algorithm:
1. **Bulk-fetch the remote index once per push** (list since epoch): map `task_id → (recordId, client_updated_at)` — avoids per-item lookups and 429s.
2. Drain pending items oldest-first, each gated by backoff (`retryCount` → wait **5s / 10s / 30s / 60s / 300s**).
3. Apply the **LWW payload guard** (§9.3); then create (`POST /api/collections/tasks/records`, `id:""`) / update (`PATCH …/{recordId}`) / delete (`DELETE …/{recordId}`, 204). Record a newly-created `recordId` into the live index so a same-drain delete finds it.
4. **Throttle ~100 ms between operations.** On HTTP **429, abort the entire push loop** immediately (items stay pending for the next cycle).
5. Other errors bump `retryCount` + `lastError`; at **5 failures** the item becomes `failed` — kept, surfaced for retry, never dropped. Failed items auto-requeue (reset to pending) on **launch, foreground, network-regained, and manual sync** — deliberately *not* on the periodic cadence or post-mutation pushes, so a poison item can't hammer a rejecting server every two minutes.

### 9.6 Realtime (SSE) + cadence safety net

Protocol (live-verified):
1. `GET /api/realtime` with `Accept: text/event-stream`, no auth, no timeout. Frames use `id:`/`event:`/`data:` lines (tolerate no space after the colon; `:` comment lines are heartbeats; an event is delimited by a blank line; multiple `data:` lines join with `\n`).
2. First frame: `event:PB_CONNECT`, `data:{"clientId":"…"}` — extract the clientId (missing → reconnect).
3. Subscribe: `POST /api/realtime` with the bare-JWT auth header, JSON body `{"clientId":"<id>","subscriptions":["tasks"]}` → 204.
4. Task events arrive as `event:tasks`, `data:{"record":{…full record…},"action":"create"|"update"|"delete"}`.

Apply rules: enforce owner **fail-closed** (non-empty `record.owner` must equal the current JWT's user id, else drop). For create/update: **echo-filter** — drop when `record.device_id` equals this device's id; drop when a local **delete** is pending for that `task_id` (don't resurrect); else LWW-upsert with device-local preservation. For delete: drop when *any* queue item is pending for that task (deletes carry the last writer's `device_id`, so they are **not** echo-filtered — the queue check is the guard); else delete locally.

Lifecycle: SSE runs **foreground only**. On stream end/error: run a full sync (catch missed events), then reconnect with exponential backoff 1s → cap 30s (healthy stream resets it). **Safety net:** a full sync every **120 s** while active, plus on launch, foreground, network-regained, and a **1.5 s debounced push** after each local mutation. One sync at a time — concurrent triggers coalesce.

### 9.7 Sync history & health

- Record every attempt: `{ id, timestamp, status: success|error|conflict|partial, pushedCount, pulledCount, conflictsResolved, failedCount?, errorMessage?, duration?, deviceId, triggeredBy: user|auto }`. Precedence: error > partial (some pushes failed) > success; remote-won LWW counts as informational conflict, not failure. `triggeredBy = user` only for manual syncs. **Prune to the 500 most recent** after each insert; the history screen shows ~50.
- **Health evaluation** (priority order): offline → session expired (token expiry ≤ now) → failed items exist → stale queue (oldest pending > 1 hour) → OK. Surface as the quiet status chip (§5.10) + a human message in Settings; never alarming.

### 9.8 Device identity & remote erase

- On first run generate a stable `deviceId` (UUID) + a human `deviceName` (model); persist locally. `deviceId` populates `device_id` on pushes (echo filtering) and sync history.
- **Erase-all-remote** (used by erase-everywhere and account deletion): list the full remote index fresh, `DELETE` every record (~100 ms throttle), and only clear the local queue after **all** deletes succeed. A dead session throws (so callers refuse to wipe local data on a false "success"); signed-out is a silent no-op.

---

## 10. Authentication

### 10.1 Providers

**Google, GitHub, and Sign in with Apple** — all already configured on the PocketBase backend and all delivered through PocketBase's **web OAuth flow** (no Google Play sign-in SDK, no provider SDKs). Onboarding offers Apple + Google; Settings offers all three (parity with iOS).

### 10.2 The flow (OAuth2 + PKCE via Custom Tabs)

1. `GET /api/collections/users/auth-methods` → `oauth2.providers[]`, each `{name, displayName, state, authURL, codeVerifier, codeChallenge, codeChallengeMethod}`. **PocketBase generates the PKCE material per attempt** — hold it locally, never cache it.
2. Build the authorization URL: the provider's `authURL` already ends with `redirect_uri=` — append the percent-encoded redirect URI.
3. **Redirect URI: `https://api.vinny.io/ios-oauth-redirect/`** — a server-side bounce page that re-emits the provider callback to the **`gsd://` custom scheme**. This bounce is what makes Apple work (Apple posts `response_mode=form_post` to an HTTPS URL; the page forwards `code`/`state` to the app scheme). Android registers an intent filter for the `gsd` scheme and receives the same bounce. *(Despite the "ios-" name it is client-agnostic; see Open Questions §17.)*
4. Launch the URL in a **Custom Tab**; the `gsd://` callback re-enters the app with `code` + `state` query params.
5. **Validate `state`** against the provider's issued state (mismatch → abort).
6. `POST /api/collections/users/auth-with-oauth2` with JSON `{"provider","code","codeVerifier","redirectURL"}` → `{token, record:{id, email, …}}`.
7. Persist the token (Keystore-encrypted, §3). The JWT's `id` claim is the `owner` for pushed records; a token without an `id` claim fails fast.

### 10.3 Token lifecycle

- PocketBase JWTs live ~14 days; there is **no refresh token**. When the token expires within a **7-day skew**, call `POST /api/collections/users/auth-refresh` (bare-JWT auth header, no body) → fresh `{token, record}`.
- A **transient** refresh failure (offline, 5xx) falls back to the still-valid stored token — offline-first means network failures **never** sign the user out. Clear the stored token **only** on a definitive 401/403.
- Decode the JWT payload locally (base64url, no signature verification) for `id` and `exp` only.

### 10.4 Identity caveats

- Cross-provider identity: each OAuth provider identity is a distinct PocketBase user unless the backend links them. A user who signs in with Google on the web and Apple on Android gets **two data spaces**. Surface provider choice clearly; recommend users pick the same provider everywhere.
- **Apple private relay:** an `…@privaterelay.appleid.com` email means Apple relay — show a gentle note in Settings (it also implies no email-based convergence with other providers).
- Account switching semantics: §8.21.

---

## 11. Notifications & Background (a redesign, not a port)

iOS pre-schedules every reminder with the system notification center; Android's analog is **exact alarms**. Same user-visible outcome: reminders fire on time with no polling.

### 11.1 Scheduling model (behavior shared with iOS)

- A task with a `dueDate`, `notificationEnabled == true`, and a reminder offset (`notifyBefore`, else the global default) gets a reminder at `dueDate − offset` — unless `snoozedUntil` is in the future, in which case the fire time **is** `snoozedUntil`.
- **Reschedule** whenever `dueDate`, `notifyBefore`, `notificationEnabled`, snooze, or completion changes; **cancel** on complete, delete, or disable. Editing `dueDate`/`notifyBefore` resets reminder state (§8.3). Recurring spawns schedule their own reminder at spawn time.
- **Quiet hours:** a fire time inside the quiet window defers to the window's end.
- One stable identity per task (`task-<id>`) so reschedules replace, never stack.
- **Resync on any data change:** remote pulls and SSE writes bypass local mutation hooks, so a debounced (~1 s) full reminder resync runs off the store's change stream — reminders stay correct no matter which device edited the task.

### 11.2 Android mechanics

- `AlarmManager.setExactAndAllowWhileIdle` for fire times, with the **`SCHEDULE_EXACT_ALARM`** permission (user-grantable special access). If exact alarms are not permitted, degrade gracefully to inexact windows and say so in Settings — never silently fail.
- A `BroadcastReceiver` posts the notification at alarm time: title = task title, body = description (if any), tap → `gsd://task/<id>`.
- **Notification channels:** *Reminders* (default importance, sound) and *Reminders (silent)*; the in-app **Sound** toggle selects the channel (channel sound is user-owned on Android — the two-channel split is the honest mapping).
- **Runtime permission:** `POST_NOTIFICATIONS` requested **contextually** (first reminder enablement / first due date with reminder), never at cold launch. Track `permissionAsked`; reflect OS state in Settings with a path to system settings when denied.
- **Reboot / update:** alarms die on reboot — a `BOOT_COMPLETED` (+ `MY_PACKAGE_REPLACED`) receiver reschedules everything from the store.
- Mark `notificationSent`/`lastNotificationAt` when a reminder posts (device-local, §4.7).

### 11.3 Badges

Android has no numeric app-icon badge API; the notification channel's badge dot is the platform behavior. The iOS-style due-soon badge count has **no Android analog** — accepted delta.

### 11.4 Notification actions (Android-native win)

Reminder notifications carry two action buttons: **Complete** (full completion semantics — recurrence spawn, sync enqueue) and **Snooze 1 hour**. Both act through the store without opening the app and dismiss/update the notification.

### 11.5 Background work

One periodic **WorkManager** job (~hourly, battery-friendly constraints): auto-archive sweep (§8.12) + an **opportunistic sync** when signed in (Android can do what iOS couldn't reliably — data is fresh on next open). Reminders never depend on background work; they're pre-scheduled alarms.

---

## 12. Android-Native Surfaces

### 12.1 Home-screen widget (Glance)

**Today's Focus** — the one widget (parity with shipped iOS):
- Sizes: small (~2×2; up to 3 tasks) and medium (~4×2; up to 5), "+N more" overflow, "All clear" empty state, "Today's Focus" header with the crosshair glyph.
- Content: the Q1-active task list (title + optional due). Styled with GSD tokens (paper/surface, ink, Rust accents) in both light/dark.
- Data: a precomputed snapshot pushed by the app on every relevant data change (Glance is push-updated — no timeline needed).
- Taps: widget body → `gsd://smart-view/today-focus`; each row → `gsd://task/<id>`.

### 12.2 Share target (the Share-Extension analog)

An `ACTION_SEND` (`text/plain`) share target: sharing a URL or text from any app opens a compact **"Add to GSD"** compose sheet:
- Editable **Title** — prefilled from shared text; a bare URL derives a readable title from the URL (host/path words). Empty → **"Review link below"**. Clamped to 80 chars.
- **Quadrant picker** defaulting to **Eliminate (Q4)**.
- Comma-separated **tags** field with live chips (normalized: trim/lowercase/dedupe/≤30 chars/max 20).
- Read-only **Link** section: URLs sanitized by the §8.2 rules land in the description (newline-joined, clamped to 600).
- **Add** writes directly through the store (same process — no outbox dance needed) and enqueues sync; errors keep the sheet open. Optional post-save title enrichment (fetch the page title) only when the "Fetch titles for shared links" setting is on and the title is still URL-derived.

### 12.3 App shortcuts & assistant surface

- Static launcher shortcuts: §6.5.
- There is **no good Android analog** of iOS App Intents/Siri/Spotlight in 2026 (Assistant App Actions are deprecated); skip rather than ship a broken voice surface. The MCP server already provides the AI/automation path against the shared backend. Revisit if a stable Android assistant-integration API lands.

### 12.4 System integration baseline

Predictive back; edge-to-edge; per-app language support wiring (English at launch); direct-share is out of scope.

### 12.5 Launcher icon

The adaptive icon (§5.9): pigment-tile foreground, paper background, monochrome layer for themed-icon launchers.

---

## 13. Non-Functional Requirements

### 13.1 Offline-first (a correctness constraint)

Fully functional with no network and no account. All reads/writes hit the local store synchronously-fast; sync is a background reconciliation layer, never on the critical path of a user action. Optimistic UI everywhere; failures surface as calm, undoable errors. **UI copy must never imply data leaves the device when it doesn't.**

### 13.2 Performance

Cold start to interactive quickly (baseline profiles); the matrix smooth with hundreds of tasks; sync, analytics, and import/export off the main thread; the widget reads a snapshot, not the database.

### 13.3 Accessibility (baseline — required)

- **TalkBack:** every interactive element labeled; cards expose a coherent reading order (title, quadrant, due, status) and **custom accessibility actions** for complete/snooze/edit/delete (swipe gestures are not the only path).
- **Font scale:** `sp` everywhere; layouts reflow at 2× / non-linear scaling; no clipped fixed-height text.
- **Reduced motion:** confetti and non-essential animation suppressed when animations are disabled (§5.8).
- **Contrast:** the quadrant accents meet WCAG **AA** against their card backgrounds in both modes (the §5.1 values are pre-verified — don't "brighten" them).
- **Touch targets ≥ 48dp**; full keyboard operability on hardware keyboards.

### 13.4 Privacy & security

Local-only by default; **no analytics/tracking**. Tokens Keystore-encrypted, never logged. HTTPS only. The §8.2 URL sanitizer is security-relevant — replicate exactly. Logging is structured with secret/content masking: never log task content or tokens.

### 13.5 Error handling

Typed errors (not-found / validation / network / auth); human, actionable user copy; technical detail only in logs; sync errors always recoverable (queue persists; manual retry).

### 13.6 Testing & verification

- **JVM unit tests** (`:core:model`) for all pure logic — port the shared behavior as fixtures: capture-parser grammar (incl. URL sanitization edge cases), quadrant derivation, recurrence date math (month-end clamping), BFS cycle detection, the filter pipeline, time-spent calculation, analytics math, import merge/ID-remap (forward references), validation limits.
- **Sync engine tests** (`:core:sync`, JVM) against recorded PocketBase fixtures: LWW both directions (incl. equal-ms no-op), device-local preservation, deletion reconciliation with queue protection, cursor advance/5s rewind + space-form dates, 429 abort, backoff schedule, echo filtering, SSE frame parsing (PB_CONNECT, multi-line data, comment heartbeats), lossy time-entry round-trip.
- **Room migration tests** (instrumented) per schema version.
- **Compose UI tests** for the matrix, editor, and adaptive layouts; a launch smoke test per release.
- TDD (red → green → refactor) per the adopted coding standards. The JVM suite is the gate and must stay fast.

---

## 14. Google Play Requirements

- **Data Safety form (accurate to behavior):** local-only mode collects nothing and shares nothing. With optional sync: task content is stored on the developer's self-hosted backend, tied to an account identifier; encrypted in transit; user-deletable (in-app account deletion — which Play requires to be discoverable, and which §8.21 provides). No third-party sharing, no ads, no analytics SDKs.
- **Account deletion:** Play mandates an in-app path *and* a web-accessible deletion method for apps with account creation — the in-app flow exists (§8.21); the web deletion URL is an owner item (§17).
- **Permissions:** `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM` (with the Play Console declaration for exact-alarm use: user-facing task reminders), `RECEIVE_BOOT_COMPLETED`, `INTERNET`. Nothing else.
- **Target API:** current Play minimum (target the latest stable SDK).
- **Listing:** name "GSD — Get Stuff Done" (or match the App Store listing), privacy policy `https://gsdtaskmanager.com/privacy/`, phone + tablet screenshots (Play surfaces large-screen quality ratings — the 2×2 grid is the tablet hero shot).

---

## 15. Phased Roadmap

Each phase independently buildable and testable; sync remains the highest-risk phase — budget accordingly.

- **Phase 0 — Foundations.** Repo, Gradle modules (`:core:model` / `:core:store` / `:core:sync` / `:app`), theme system (§5 tokens, Newsreader, dark mode), Room schema v1 + migrations scaffold, the Task model + embedded types, ID generation, validation. JVM tests green.
- **Phase 1 — Core local app.** Matrix (compact stack + expanded 2×2), capture bar **with the full parser**, editor, complete/uncomplete + confetti + haptic, delete + undo snackbar, show-completed, theming. Pure offline. Parser/quadrant/validation fixtures ported.
- **Phase 2 — Task depth.** Due dates + presets, recurrence engine, subtasks, snooze, dependencies + BFS, time tracking.
- **Phase 3 — Organization & insight.** Archive (manual + auto), smart views (9 built-ins + custom + pinning), search + command palette, dashboard, import/export, onboarding/Help/About.
- **Phase 4 — Notifications.** Exact alarms, channels, runtime permission flow, quiet hours, boot rescheduling, notification actions, the WorkManager maintenance job (sans sync).
- **Phase 5 — Sync.** The PocketBase client (REST + SSE), Custom-Tabs OAuth + PKCE (all three providers), Keystore tokens, the LWW engine (pull/push/reconcile/queue/history/health), account switch/delete, erase-everywhere, opportunistic background sync. Live-backend validation early; recorded fixtures throughout.
- **Phase 6 — Native surfaces.** Glance widget, share target, app shortcuts, deep-link hardening.
- **Phase 7 — Play readiness.** Data Safety form, adaptive icon + listing assets, accessibility audit (TalkBack + 2× font + reduced motion), baseline profile, internal testing track.

> Phases 0–4 ship a genuinely useful local-only app — consistent with "sync is optional."

---

## 16. Open Questions & Risks

1. **The OAuth bounce page** (`https://api.vinny.io/ios-oauth-redirect/`) — verify it is client-agnostic (it forwards to the `gsd://` scheme, which Android also registers). If anything about it is iOS-conditional, add a parallel `android-oauth-redirect` (server-side, trivial). **Owner: backend. Blocking for Phase 5.**
2. **Cross-provider identity** — unchanged ecosystem-wide caveat (§10.4): provider mix-ups create separate data spaces. Mitigated by guidance copy; account linking remains a backend wishlist item.
3. **Web-accessible account deletion URL** — required for the Play Data Safety form (§14). **Owner: backend/site.**
4. **Exact-alarm permission UX** — if Play policy review pushes back on `SCHEDULE_EXACT_ALARM`, fall back to inexact alarms + copy honesty. Low risk for a task-reminder app; verify at submission.
5. **`gsd://` collision** — both GSD apps can't conflict on one device's scheme (Android and iOS namespaces are separate — non-issue — but keep route parity so shared docs/links behave identically).
6. **Newsreader rendering** — verify optical weight against iOS "New York" at the display sizes; adjust weight (regular→medium) if it reads thin on OLED dark.
7. **PocketBase page-size ceiling** — pulls page at 200; users beyond ~10k tasks are untested ecosystem-wide (import caps at 10k). Accepted.
8. **iOS ID-length quirk** — iOS emits some 12-char task IDs (an internal inconsistency); all clients must accept any URL-safe ID ≥ 4 chars. Android emits 21 and must not validate others' lengths.

---

## Appendix A — Authoritative enumerations (quick reference)

- **Quadrants:** `urgent-important` (Do First) · `not-urgent-important` (Schedule) · `urgent-not-important` (Delegate) · `not-urgent-not-important` (Eliminate). Order Q1→Q4.
- **Recurrence:** `none`, `daily`, `weekly`, `monthly` (no yearly).
- **Snooze presets:** 15 min, 30 min, 1 h, 3 h, Tomorrow (+1d), Next week (+7d); quick-snooze 1 h; max 365 days.
- **Reminder offsets (editor):** none, 0 (at time), 5, 15, 30, 60, 120, 1440 min. **Default-reminder presets (settings):** 15, 30, 60, 120, 1440 (default 15).
- **Due-date presets:** None · Today · This week (Friday; weekend → next Friday) · Next week (Monday).
- **Archive after:** 30 / 60 / 90 days (default 30).
- **Trend windows:** 7 / 30 / 90 days.
- **Sync:** cadence 120 s · mutation debounce 1.5 s · push throttle ~100 ms · backoff 5/10/30/60/300 s · max 5 retries then `failed` · pull `perPage` 200 · cursor rewind **5 s** · SSE reconnect 1 s → 30 s cap · history kept 500 / shown 50 · stale-queue threshold 1 h · token refresh skew 7 d.
- **Built-in smart-view IDs:** `today-focus`, `this-week`, `overdue`, `no-deadline`, `recently-added`, `weeks-wins`, `all-completed`, `recurring`, `ready-to-work`.

## Appendix B — Field limits

| Limit | Value |
|---|---|
| ID | ≥ 4 chars (emit 21; time entries 8; smart views 12) |
| Title | 1–80 chars |
| Description | 0–600 chars |
| Tag | 1–30 chars, max 20, lowercase |
| Subtask title | 1–100 chars, max 50 |
| Dependencies | max 50 |
| Time entries | max 1000; note ≤ 200 chars |
| Estimated minutes | 1–10080 (0 = unset) |
| Smart-view name | 1–60 chars |
| Pinned views | max 5 |
| Share-capture title | clamped to 80 chars |
| Import | ≤ 10,000 tasks, ≤ 10 MB |

## Appendix C — Capture-parser test vectors (port as fixtures)

| Input | Result |
|---|---|
| `Ship the deck !! #work` | title "Ship the deck", Q1, tags [work] |
| `Call mom !` | title "Call mom", urgent only → Q3 |
| `Plan trip *` | title "Plan trip", important only → Q2 |
| `Read newsletter` | Q4 (no flags) |
| `Check https://example.com/a then report !` | URL moved to description, title "Check then report", Q3 |
| `Read https://example.com/doc.` | URL captured **without** the trailing `.`, moved to description |
| `https://example.com` | title "Review link below", URL in description |
| `Fix login !!#auth #AUTH` | tags dedupe → [auth] |
| `Danger http://user:pass@evil.com` | URL rejected → left in title |

*— end of specification —*
