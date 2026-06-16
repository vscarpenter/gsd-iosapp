# Account Deletion (App Store Guideline 5.1.1(v)) — Design

**Status:** Approved design, ready for implementation planning.
**Date:** 2026-06-16
**Branch:** `account-deletion` (off `main`).

## Why

App Review rejected the App Store submission of GSD under **Guideline 5.1.1(v) — Data Collection and Storage** (Submission ID `7cfd62aa-6da1-4ed5-b08e-35da1d9f7f88`, reviewed 2026-06-16):

> The app supports account creation but does not include an option to initiate account deletion. Apps that support account creation must also offer account deletion…

GSD lets a user create/sign in to an account (PocketBase `users` record via Google / Apple / GitHub OAuth). It must therefore offer **in-app account deletion**. The same gap will block the Mac (Catalyst) submission, so the fix targets both platforms at once.

## Scope

**In scope:**
- A signed-in user can delete their account entirely **in-app** (no web hand-off).
- Deletion removes the **PocketBase `users` record** and **all the user's server-side tasks**, and ends the session.
- At deletion, the user **chooses the fate of their on-device tasks**: keep them (stay usable offline) or erase everything.
- Works identically on **iPhone, iPad, and Mac Catalyst** (shared SwiftUI + GSDKit).

**Out of scope (explicit):**
- Deleting/revoking the upstream OAuth grant at Google/Apple/GitHub (not required by Apple; the *app's* account is what's deleted).
- Remotely wiping the local database on the user's *other* devices (impossible; each device clears itself on its next failed auth).
- Any change to the signed-out/offline experience (the app remains fully usable with no account).

## Locked decisions

1. **In-app deletion**, not a web link. (We own the PocketBase backend and already have the REST primitives.)
2. **Let the user choose** the local-data outcome at the confirmation step.
3. **Single confirmation** — one dialog with two clearly-labeled destructive choices; no "type DELETE" friction (allowed by Apple; the app is not a highly-regulated industry).

## Architecture

The flow is shell-thin on top of existing, tested machinery. Responsibilities stay separated:

- **`AuthService` (GSDSync)** — *account authority.* New `deleteAccount()` issues the authenticated `DELETE /api/collections/users/records/{id}` (via the existing `authedRequest` + `sendNoContent`), using `currentUserId()` for the id and a fresh `validToken()`. Maps 401/403 → auth-rejection, network/5xx → surfaced error. Clears the Keychain token only after a confirmed delete.
- **`SyncEngine.eraseAllRemote()` (GSDSync)** — *reused as-is* to delete the user's server tasks before the account record goes (once the user is deleted, the token is invalid and tasks can no longer be removed).
- **`SessionStore` (App/Auth)** — *orchestrator + local teardown.* New `deleteAccount(eraseLocalData:) async` runs the ordered flow, mirrors the existing `inProgress`/`lastError` surface, and reuses `signOut()` (Keychain/email/owner/coordinator teardown) plus the already-injected `eraseLocal` closure (`eraseAllData`) when the user chose "erase everything."
- **`SettingsView` (App/Settings)** — *entry point.* A destructive "Delete Account…" row in the Account section (shown only when `session.isSignedIn`) + the confirmation dialog.

Because every piece is in shared code, **one implementation covers iOS and Mac** with no `#if` branches.

## The flow

### Entry point
In `SettingsView`'s Account section, when `session.isSignedIn`, add a **destructive "Delete Account…"** row beneath "Sign Out."

### Confirmation (the "let the user choose" decision)
Tapping it presents a `confirmationDialog` (the same pattern as the existing account-switch dialog):

> **Delete your account?**
> This permanently deletes your account and every task synced to it. This can't be undone.

Actions:
- **Delete & keep tasks on this device** (`role: .destructive`) → `deleteAccount(eraseLocalData: false)`
- **Delete & erase everything** (`role: .destructive`) → `deleteAccount(eraseLocalData: true)`
- **Cancel** (`role: .cancel`)

### Deletion logic (ordered — order matters)
`SessionStore.deleteAccount(eraseLocalData:)`:

1. **Guard a live session.** `validToken()` (refreshes if near expiry) and `currentUserId()`. If no usable token/id → `lastError` = "Your session expired — sign in again to delete your account." and stop (no destructive action).
2. **Delete server tasks.** `SyncEngine.eraseAllRemote()`. If it fails → abort, surface error, **nothing else happens** (account intact, retryable).
3. **Delete the account record.** `AuthService.deleteAccount()` → `DELETE …/users/records/{id}`. On 2xx, clear the Keychain token.
4. **Local teardown (only after step 3 confirms).** `signOut()`; then, iff `eraseLocalData`, run `eraseLocal()` (`eraseAllData` — also clears the sync queue, reminders, and badge).

## Error & edge handling

This is the part a careless implementation gets wrong; the rules:

- **Offline / network / 5xx at any remote step:** abort and surface an error. **Never** sign out or wipe local data while the remote account still exists. (Same invariant already hardened into `eraseEverywhere`: don't destroy local while remote survives.)
- **401/403 (dead session):** can't authenticate the delete → tell the user to sign in again rather than failing opaquely.
- **Partial failure** (tasks erased, user-record delete failed): retryable and safe — a re-run re-erases tasks (no-op) and retries the record delete. A momentarily empty-but-existing account is benign.
- **Ordering guarantee:** local wipe happens strictly after the account-record delete returns success.
- **Double-tap / in-progress:** `inProgress` gates the button (as sign-in already does).

## Backend change (owner ops, PocketBase @ api.vinny.io)

One **required** change: the `users` collection **Delete rule** must permit self-deletion:

```
@request.auth.id = id
```

(Today it is almost certainly admin-only, so the authenticated `DELETE` would 403.)

**Optional defense-in-depth:** set the `tasks.owner` relation to **cascade-delete**, so a deleted user can never leave orphaned task records even if the client's `eraseAllRemote` is interrupted. The client erasing tasks first is what *guarantees* correctness; cascade is a belt-and-suspenders net. This mirrors the prior Sign-in-with-Apple backend setup — a small, owner-side change.

## iOS + Mac coverage

The entry point (`SettingsView`), orchestration (`SessionStore`), and remote logic (`AuthService`/`SyncEngine`) are all shared, platform-agnostic code. The single implementation satisfies the iOS resubmission **and** the future Mac (Catalyst) submission. On Catalyst it appears in the same Settings detail pane.

## Testing

- **Unit (GSDSync, no backend — reuse the existing fake `PocketBaseClient`/`TokenStore` seams):**
  - `AuthService.deleteAccount()` builds the correct request: `DELETE`, path `…/users/records/{currentUserId}`, auth header present; success clears the token; 401/403 maps to auth-rejection; network error is surfaced (token *not* cleared).
  - `SessionStore.deleteAccount(eraseLocalData:)` orchestration: on remote success → `signOut` called, and `eraseLocal` called iff `eraseLocalData`; on remote failure → **no** `signOut`/`eraseLocal`, `lastError` set; ordering (erase-tasks before delete-record) verified via a stateful fake.
- **Manual smoke (live api.vinny.io):** both paths (keep / erase-everything), plus the offline-abort path.

## Rollout & resubmission

- Ship on `main` as the next iOS build (a patch over 1.7.x) for the App Store resubmission. The Catalyst branch inherits it on its next rebase/merge from `main`.
- Capture a **physical-device screen recording** for App Review Notes: sign in with the demo account → Settings → Delete Account → the full flow to confirmation. (Owner action; required by the rejection notice for future submissions.)
- Note for the owner: the rejection cites "Version reviewed: 1.0 (8)" while TestFlight is at 1.7.0 (17) — confirm the App Store *version record* you resubmit includes this build.

## Files

**Modify:**
- `App/Settings/SettingsView.swift` — "Delete Account…" row + confirmation dialog in the Account section.
- `App/Auth/SessionStore.swift` — `deleteAccount(eraseLocalData:) async` orchestration + state surface.
- `GSDKit/Sources/GSDSync/AuthService.swift` — `deleteAccount()` (authenticated user-record DELETE).
- `GSDKit/Sources/GSDSync/PocketBaseClient.swift` — only if a thin delete helper is warranted (else reuse `authedRequest` + `sendNoContent`).

**Reference (read, don't change):**
- `GSDKit/Sources/GSDSync/SyncEngine.swift` — `eraseAllRemote()` (reused).
- `App/ContentView.swift` — the existing account-switch `confirmationDialog` pattern to mirror.

**Backend (owner, not in repo):** PocketBase `users` delete rule (`@request.auth.id = id`); optional `tasks.owner` cascade-delete.

## Risks / open items

1. **`users` delete rule** must be enabled before the client flow can succeed end-to-end (otherwise a clean 403). Verified at the manual smoke.
2. **Self-deletion semantics in PocketBase** — confirm a user authenticated with their own token may delete their own `users` record under the rule above (expected; verify live).
3. **App Store version record** — the 1.0(8)-vs-1.7.0(17) discrepancy above is a release-management item for the owner, not a code concern.
