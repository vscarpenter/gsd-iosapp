# Tappable URLs from Share-captured tasks

**Date:** 2026-06-24
**Status:** Approved — ready for implementation

## Problem

When a user adds an item to GSD via the iOS/iPadOS Share sheet, the shared URL is
sanitized and stored in the task's `description`, but it renders as inert plain
text. The user wants the URL to be **tappable** in the app, with the same safety
posture they expect from the web ("well-formed, safe URL, no XSS, strong CSP as a
safety net").

## Key constraint: this is a native app, not a web client

GSD-iOS has **no `WKWebView` anywhere** (verified by grep across the tree). The
shared URL is rendered with a plain SwiftUI `Text`, not an HTML document. Two of
the three requested web-security terms therefore have **no surface to attach to**:

- **XSS** is script injection into a *rendered HTML document*. SwiftUI `Text`
  parses no markup and runs no script, so there is no document to inject into.
- A **Content-Security-Policy header** is an *HTTP response header* a browser
  enforces. The native binary serves no HTTP and renders no document, so a literal
  CSP header has nowhere to live. CSP belongs to the **web client**
  (`gsdtaskmanager.com`), not this app.

The *intent* — defense in depth so a hostile shared URL can do no harm — maps
directly onto native equivalents, which this design implements:

| Requested (web) | Native equivalent in this design |
| --- | --- |
| No XSS | **Scheme allowlist** via `URLSanitizer` (http/https only, no embedded credentials, ≤2048). The only thing ever handed to `openURL` is a re-vetted URL — never executed, only opened. |
| Link can't be spoofed | **Render the URL string as its own label** (label == destination). No "click here" can hide a different target. |
| CSP safety-net header | No surface in a native app. Documented here and in code; the safety net is the sandboxed system browser the OS opens via `openURL`. |

## Decisions (from brainstorming)

1. **CSP scope:** Native-equivalent safety nets only. No web changes. Documented why.
2. **Open behavior:** System default browser via the environment `openURL`
   (SwiftUI `Link`), matching existing house style (`SettingsView.swift:358`).
3. **Placement:** Editor only — a read-only, tappable "Links" section. Avoids the
   card's tap-to-edit gesture conflict (the Mac-Catalyst completion-disc class of
   bug) and the description field's edit-mode selection conflict.
4. **Detection:** Any http/https URL in the description, re-validated through
   `URLSanitizer`. Covers share-captured **and** manually-typed/synced URLs with
   no provenance tracking and no special-casing.

## Architecture & data flow

The capture path, model, and store are unchanged. The feature only **surfaces**
already-stored URLs.

```
Share sheet → SharedCapture.urls (raw)
            → URLSanitizer (http/https, no creds, ≤2048)        [EXISTING]
            → task.description (newline-joined)                  [EXISTING]
            ↓
Open task in editor
            → LinkDetector.detect(in: description)              [NEW — pure, GSDModel]
            → "Links" section: one Link per vetted URL          [NEW — TaskEditorView]
            → tap → environment openURL → system browser
```

## Components

### 1. `LinkDetector` — new pure type in `GSDModel`

Zero-dependency, Foundation-only, unit-tested via `swift test` (the fast loop).

```
public enum LinkDetector {
    public static func detect(in text: String) -> [URL]
}
```

- Uses `NSDataDetector` with the `.link` checking type to find URL ranges.
- For each match, takes the **matched substring** and re-validates it through
  `URLSanitizer.sanitize` (the codebase's single source of truth for "safe URL").
  Only survivors become `URL`s, built from the sanitized string.
- De-duplicated, original order preserved. Returns `[]` for empty / no matches.
- Re-validation rationale: descriptions can also originate from manual typing and
  sync from the web client, so the stored string is never trusted. Keeping
  `URLSanitizer` as the one allowlist means a URL is vetted both where it is born
  (share capture) and where it is surfaced (the editor). Conservatively does
  **not** link bare `www.foo.com` (no explicit scheme) — safe by design.

### 2. "Links" section in `TaskEditorView`

Inserted immediately after the Notes section (`TaskEditorView.swift:83`).

- Computes `LinkDetector.detect(in: description)` reactively from the `description`
  `@State`. Renders nothing when the result is empty.
- Each row: `Link(destination: url) { Text(verbatim: url.absoluteString) }`,
  `.lineLimit(1)`, `.truncationMode(.middle)`, action tint. The label **is** the
  destination. `Link` routes through the environment `OpenURLAction`, which opens
  the system default browser.
- Appears live as the user types/pastes a URL, and on any share-captured task when
  it is opened in the editor.

## Error handling / edge cases

- No URLs → no section rendered (never an empty "Links" section).
- Malformed / over-length / `user:pass@` or `%40` credential smuggling /
  non-http(s) schemes (`javascript:`, `data:`, `file:`, `mailto:`) → silently
  dropped by the detector.
- Duplicate URLs in the description → shown once.

## Testing

- **`swift test`** — new `LinkDetectorTests` covering: single & multiple links,
  dedup, link embedded in surrounding text, trailing sentence punctuation,
  rejection of `javascript:`/`data:`/`file:`/`mailto:`, rejection of `user:pass@`
  and `%40` credential smuggling, rejection of bare `www.`, over-length cap,
  empty / no-URL input.
- **App build** — `xcodebuild` for iPhone (`iPhone 17 Pro`) and iPad
  (`iPad Pro 13-inch (M5)`), plus the install-launch smoke check (the App target
  has no unit-test target).

## Files

- NEW `GSDKit/Sources/GSDModel/LinkDetector.swift`
- NEW `GSDKit/Tests/GSDModelTests/LinkDetectorTests.swift`
- EDIT `App/Editor/TaskEditorView.swift` (add the Links section)
- NEW this design doc

No `project.yml` / `xcodegen` change needed — new files land in already-globbed
source directories.

## Out of scope

- Tappable links on the matrix/list card (gesture conflict; deferred by decision).
- In-app `SFSafariViewController` browsing (system browser chosen).
- Any change to the web client's CSP (separate repo; recommendation noted above).
