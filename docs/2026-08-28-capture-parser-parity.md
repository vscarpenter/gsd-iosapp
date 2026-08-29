# Capture-parser parity: the shared corpus and the six (plus three) reconciliations

**Date:** 2026-08-28
**Repos:** `gsd-iosapp` and `gsd-taskmanager`, branch `fix/capture-parser-parity` in each
**Corpus:** `GSDKit/Tests/GSDModelTests/Fixtures/capture-parser-corpus.json` ↔
`gsd-taskmanager/tests/fixtures/cross-platform/capture-parser-corpus.json` (byte-identical;
both suites run every case)

## Why

The two capture-parser implementations had six documented behavioral divergences (workspace
`CLAUDE.md`, 2026-08-28 audit), every one of which syncs onward once a task is created. Each
suite tested its own implementation — a mirror, not a check — the same failure mode that let
cross-client backups break while every unit test passed. This applies the backup-fixture-pair
discipline to the parser: one corpus of inputs and expected parses, run from both suites, so
the next drift fails a test instead of shipping.

## The decisions

Each divergence was resolved by deciding the correct behavior — spec §6.2 first, product
intent second — not by defaulting to either side.

| # | Divergence | Decision | Why |
|---|---|---|---|
| 1 | Tag charset: web `[a-z0-9_-]`, iOS Unicode `\w` | **Unicode (iOS)** | Spec is silent; web's zod schema already accepts any string ≤ 30, the editors on both platforms impose no charset, and the web behavior didn't just reject `#café` — it mangled it (tag `caf`, stray `é` left in the title). First char is a word character; hyphens may follow (`\w[\w-]*`). |
| 2 | Duplicate tags: iOS dedups, web didn't | **Dedup (iOS)** | Spec §6.2 says "deduplicated" outright. |
| 3 | Over-cap tags: web rejected the create, iOS truncates at 20 | **Truncate (iOS)** | Spec §6.2 says "capped at 20". Frictionless capture (PRODUCT.md principle 4): a 21-tag capture keeps the first 20 rather than failing the whole thought. Over-cap and over-length tags are dropped from the tag list but still stripped from the title. |
| 4 | URL token boundary: web `\b` (matches after any non-word char), iOS whole-token prefix | **Boundary (web)** | iOS missed the common paren/quote-wrapped link — `see (https://a.co)` extracted nothing. The boundary rule (start-of-string or after a non-word char, ASCII word class to match JS `\b`) plus the web's URL character class now lives in both parsers. `foohttps://…` stays text on both. |
| 5 | URL storage: web `new URL().href` (normalized), iOS raw string | **Raw (iOS)** | WHATWG `href` normalization (trailing slash, punycode, percent-encoding) is effectively unreproducible byte-for-byte from Foundation, so normalized storage makes cross-client parity untestable. Both clients validate via their URL parser but store the candidate exactly as typed (post trailing-punctuation trim). |
| 6 | 2048 off-by-one: web accepted exactly 2048 chars, iOS rejects | **Reject ≥ 2048 (iOS)** | Spec §6.2: "reject URLs ≥ 2048 chars", verbatim. |

Three undocumented divergences surfaced while building the corpus, resolved the same way:

| # | Divergence | Decision |
|---|---|---|
| 7 | Duplicate URLs: iOS collapsed them, web appended twice | **Dedup** — repeats are still removed from the title, appended to the description once. |
| 8 | Repeated flag tokens (`!! !! x`): iOS stripped all, web left the second | **Strip all** — the web's flag regexes now use a lookahead for the trailing separator so adjacent tokens match in one pass. |
| 9 | Tag removal whitespace: iOS consumed the leading space (`buy #milk, now` → `buy, now`), web kept it (`buy , now`) | **Consume (iOS)** — the web replacer returns `""` instead of the leading group. |
| 10 | Leading-hyphen "tag" (`#-dash`): old web pattern matched it, iOS never did | **Not a tag (iOS)** — first character must be a word character. |

## What changed where

- **iOS** — `CaptureParser.parse` step 1 rewritten from whitespace-token scanning to
  boundary-anchored regex extraction (decision 4). Everything else already matched.
- **Web** — `lib/capture-parser.ts`: Unicode tag pattern with length/dedup/cap enforcement
  (1–3, 9, 10), lookahead flag regexes (8), `sanitizeTitleUrl` returns the raw candidate and
  rejects ≥ 2048 (5, 6), `extractUrlsFromTitle` dedups (7). The MCP server's vendored mirror
  (`packages/mcp-server/src/text/capture-parser.ts`) received the identical function-body
  edits; its parity test enforces that textually.
- **Both** — the corpus fixture plus a harness test per suite
  (`CaptureParserCorpusTests.swift`; `tests/data/capture-parser-corpus.test.ts`, which
  composes `parseCapture` → `extractUrlsFromTitle` exactly as the real capture path does).

## Changing parser behavior from here

Decide the behavior first, then regenerate the corpus **in both repos** (keep the copies
byte-identical) and change both implementations in the same pair of branches. A corpus case
failing on one side only means that side has drifted — fix the implementation, not the case.
