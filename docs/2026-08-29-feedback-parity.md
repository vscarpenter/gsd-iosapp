# Feedback parity — iOS port of the web's anonymous feedback (web #516)

**Date:** 2026-08-29
**Status:** Implemented on `feat/feedback-parity`

The iOS app mirrors the web's anonymous, opt-in feedback form: drafted locally,
sent only on an explicit tap, and preceded by a disclosure rendered from the
same `buildPayload` output that becomes the request body. The wire contract is
the web's `lib/feedback/feedback-payload.ts` + the PocketBase `feedback`
collection (`scripts/setup-pocketbase-feedback-collection.sh` in the web repo):
exactly seven snake_case fields (`submission_id`, `sentiment`, `category`,
`message`, `votes`, `app_version`, `client_submitted_at`), no auth header, no
identifier, no task content. `FeedbackTests.payloadEncodesExactlyTheSevenWireKeys`
pins the shape on this side; the web pins it with `PAYLOAD_FIELDS`.

## Deliberate divergences (owner-approved 2026-08-29)

| Divergence | iOS | Why |
|---|---|---|
| `app_version` | `ios-<version>.<build>` (e.g. `ios-2.2.0.31`), clamped to the 20-char wire limit | The shared collection's only version field; the prefix lets records be told apart by client with no schema change. Web keeps sending its bare version. |
| Roadmap list | Web's eight items minus `ios-widgets`, plus `apple-watch` | iOS already ships home-screen widgets; asking iOS users to vote for them reads as broken. `ios-widgets` is **retired on iOS — never reuse the slug**. `apple-watch` is additive; the server enumerates no slugs and the web's client-side filter ignores unknown ones. |

Everything else is byte-parity, including the nuances that are easy to get
wrong: only the unique-index 400 (`data.submission_id.code ==
"validation_not_unique"`) collapses to success — any other 400 stays a
rejection; 429 → rate-limited, ≥500 → server, transport failure → offline; the
submission id is minted per draft and reused across retries so a resend of the
same draft dedups server-side; votes are order-preserving-deduped and filtered
to shipped slugs at build time.

## Where things live

- `GSDKit/Sources/GSDModel/Feedback.swift` — draft, payload, builder, roadmap
  list (pure; cannot read the DB by construction).
- `GSDKit/Sources/GSDSync/FeedbackClient.swift` — the one network call, over
  `RequestExecuting` with a bare `URLSession`; a test asserts the Authorization
  header's absence.
- `App/Settings/FeedbackView.swift` — the screen; draft in standard
  `UserDefaults` (deliberately not the App Group — extensions have no feedback
  surface).
- Palette: "Send feedback" → `.gsdShowFeedback` → SettingsView pushes the screen.
