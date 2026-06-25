# Fetch real page titles for shared links

**Date:** 2026-06-25
**Status:** Approved — ready for implementation

## Problem

When a link is shared to GSD on **Mac Catalyst**, Safari provides only the bare
URL — no page title (confirmed: `attributedTitle`/`attributedContentText` both
nil; Catalyst doesn't honor the `WebPage` activation that would let Safari's JS
preprocessor supply `document.title`). GSD currently derives a title from the URL
slug (`URLTitle`), which works for article-slug URLs but can only yield the host
for opaque-id URLs (e.g. `ft.com/content/<UUID>` → `ft.com`). To get the **real
headline for every site**, GSD must fetch the page and read its title.

iOS already receives the real title from Safari (via `attributedContentText`), so
it needs no fetch — this feature is, in practice, the Mac/URL-only path.

## Constraint: offline-first / privacy-first

GSD is offline-first and privacy-first. A network fetch of a shared URL is a
deliberate, user-initiated action (only for links the user explicitly shares),
never background and never for existing tasks. It is gated by a setting and never
blocks task creation.

## Decisions (from brainstorming)

1. **Approach:** Pure HTML→title parser in `GSDModel` + a thin app-layer
   `URLSession` fetcher; the task is created immediately with the offline-derived
   title and the real title is fetched in the background and saved when it
   arrives. (Rejected: fetching in the Share Extension — blocks the share UI,
   and the extension is intentionally minimal/GRDB-free; fetching synchronously
   during drain — delays the task and breaks offline-first.)
2. **Privacy gate:** A Settings toggle **"Fetch titles for shared links,"**
   default **ON**. Off → no fetch ever.
3. **Scope:** Fetch only when the share carried no title (the captured title is a
   URL → it was URL-derived). iOS's real titles are not URLs and are skipped
   automatically.
4. **No entitlement change:** iOS needs none for outbound HTTP; the Catalyst
   sandbox already has `com.apple.security.network.client` (for sync).

## Architecture & data flow

```
Share (Mac) → capture(title = URL) → drain → task created NOW with the
                                              offline-derived title ("ft.com")
        ↓  (setting ON, title was URL-derived, device online)
PageTitleFetcher.title(for:) → PageTitleParser.parse(html:) →
        store.save(task with title = "Real Headline")
        ↓  on any failure (offline / timeout / non-HTML / http / no title)
        keep the derived title — no error surfaced
```

The task always appears instantly with the best offline title; the real title is
an asynchronous upgrade.

## Components

### 1. `PageTitleParser` — `GSDModel`, pure, unit-tested

```
public enum PageTitleParser {
    public static func parse(html: String) -> String?
}
```

- Prefers `<meta property="og:title" content="…">`; falls back to the
  `<title>…</title>` element.
- Decodes common HTML entities (`&amp; &lt; &gt; &quot; &#39; &#x…;`),
  collapses whitespace, trims. Returns `nil` when neither source is present or
  the result is empty.
- Pure and deterministic → fully covered by `swift test`.

### 2. `PageTitleFetcher` — app layer, I/O glue

```
func title(for url: URL) async -> String?
```

- `URLSession` GET with an ~8s timeout; reads at most ~64 KB (enough for
  `<head>`); decodes as UTF-8. Hands the body to `PageTitleParser`.
- Returns `nil` on any failure: offline, timeout, non-2xx, non-HTML, plain-`http`
  blocked by ATS, or no parseable title. Never throws to the caller.
- Thin glue over `URLSession`; verified by build + on-device smoke (the parsing
  it relies on is the unit-tested part).

### 3. Setting — `AppGroupDefaults` + `SettingsView`

- New `AppGroupDefaults` key `fetchShareTitles: Bool`, default `true`.
- A `SettingsView` toggle **"Fetch titles for shared links"** with a one-line
  note: titles are fetched only for links you share to GSD.

### 4. Enrichment wiring — app-layer share drain

- After the share drain creates a task whose **title was URL-derived**, and the
  setting is ON, fetch the real title and `store.save` the updated task.
- "Title was URL-derived" is detected statelessly: the task's `description`
  holds the shared URL, and the task's current title equals
  `URLTitle.derive(from: thatURL)` (clamped identically to the builder). iOS's
  real titles differ from the derived value and are skipped.
- The same equality check means the fetch result is applied **only if the title
  is still the derived value** — so a manual edit in the brief window is never
  clobbered.
- The update flows through `store.save`, stamping `updatedAt` and enqueuing sync,
  so the corrected title propagates to other devices.

## Error handling / edge cases

- Offline / timeout / non-HTML / `http` (ATS) / missing title → keep the derived
  title; no user-visible error.
- Setting OFF → never fetch.
- Title already changed (user edit, or an iOS real title) → do not overwrite.
- Multiple shared URLs in one capture → fetch the first; that is the captured
  link.

## Testing

- **`swift test`** — `PageTitleParser` tests: `og:title` preference, `<title>`
  fallback, entity decoding, whitespace collapse, missing/empty/malformed input.
- **Builds** — Catalyst + iPhone + iPad.
- **On-Mac smoke (owner)** — share an `ft.com` article: the task appears titled
  `ft.com`, then upgrades to the real headline within a moment; toggling the
  setting off suppresses the fetch.

## Files

- NEW `GSDKit/Sources/GSDModel/PageTitleParser.swift`
- NEW `GSDKit/Tests/GSDModelTests/PageTitleParserTests.swift`
- NEW app-layer `PageTitleFetcher.swift` (+ drain-enrichment wiring in the app)
- EDIT `GSDKit/Sources/GSDStore/AppGroupDefaults.swift` (the `fetchShareTitles` key)
- EDIT `App/Settings/SettingsView.swift` (the toggle)

## Out of scope

- Fetching titles on iOS (already provided by Safari) or for non-share tasks.
- Re-fetching/refreshing titles for existing tasks.
- Following non-HTTP schemes or adding ATS exceptions for plain `http`.
