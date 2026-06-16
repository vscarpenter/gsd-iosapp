# Account Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app "Delete Account" flow (App Store Guideline 5.1.1(v)) that deletes the PocketBase user record + all their server tasks, lets the user choose whether to also wipe local data, and works on iPhone/iPad/Mac.

**Architecture:** Thin shell over existing machinery. A new testable `AuthService.deleteAccount()` issues the authenticated user-record DELETE; the existing `SyncEngine.eraseAllRemote()` (reached via a new remote-only `SyncCoordinator.eraseRemoteTasks()`) clears server tasks first; `SessionStore.deleteAccount(eraseLocalData:)` orchestrates remote-then-local with fail-safe ordering; `SettingsView` adds the destructive row + confirmation. All shared code, so one implementation covers both platforms.

**Tech Stack:** Swift 6, GSDSync (Foundation-only, `swift test`), SwiftUI app layer (build + manual smoke), PocketBase REST.

**Spec:** `docs/superpowers/specs/2026-06-16-account-deletion-design.md`.

---

## Conventions for this plan

- **GSDSync logic is TDD** (`cd GSDKit && swift test` — sub-second, no simulator/backend). Only `AuthService.deleteAccount()` is unit-testable; that is Task 1.
- **App-layer glue** (`SyncCoordinator`, `SessionStore`, `SettingsView`) has **no unit-test target** (per `CLAUDE.md`); it is verified by a clean `xcodebuild` + the manual smoke in Task 5. Each such task's "test" is: `swift test` still green **and** the app builds for iPhone + iPad.
- No `project.yml` change in this plan ⇒ **no `xcodegen generate` needed** (only existing files are edited).

Canonical commands:

```bash
# GSDSync unit tests (Task 1)
cd GSDKit && swift test --filter AuthServiceTests

# Full package suite (regression gate after each task)
cd GSDKit && swift test

# App build gate (Tasks 2-4) — both targets are co-equal
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

---

## Files

**Modify:**
- `GSDKit/Sources/GSDSync/AuthService.swift` — add `public func deleteAccount() async throws`.
- `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift` — add `lastRequest` capture to `FakeExecutor`, a `makeJWT(id:exp:)` helper, and 4 `deleteAccount` tests.
- `App/Sync/SyncCoordinator.swift` — add `func eraseRemoteTasks() async -> Bool`.
- `App/Auth/SessionStore.swift` — add `func deleteAccount(eraseLocalData: Bool) async`.
- `App/Settings/SettingsView.swift` — `@State showDeleteAccount`, a destructive "Delete Account…" row, and a `confirmationDialog`.

**Reference (read, do not change):**
- `GSDKit/Sources/GSDSync/SyncEngine.swift:254` — `eraseAllRemote()` (reused; returns `SyncResult` with `.skipped`/`.notSignedIn`/`.error`).
- `GSDKit/Sources/GSDSync/PocketBaseClient.swift:61,85` — `authedRequest(path:method:token:body:)` (public) + `sendNoContent(_:)` (internal, same module).
- `App/Sync/SyncCoordinator.swift:104-124` — `eraseEverywhere(store:)` (the shape `eraseRemoteTasks` is modeled on, minus the local wipe).
- `App/GSDApp.swift:96-99` — how `SessionStore` is built (`eraseLocal: { try await store.eraseAllData() }`).

**Backend (owner, not in repo):** PocketBase `users` collection **Delete rule** → `@request.auth.id = id`; optional `tasks.owner` cascade-delete. Covered in Task 5.

---

## Task 1: `AuthService.deleteAccount()` (TDD, GSDSync)

**Files:**
- Modify: `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift`
- Modify: `GSDKit/Sources/GSDSync/AuthService.swift`

**Why:** This is the only unit-testable unit. It deletes the user's PocketBase record with a live token, clears the Keychain on a confirmed delete (and on 401/403 — the session is already dead), but keeps the token on a transient/network failure so the user can retry. Erasing the user's *tasks* is the caller's job and must precede this (once the record is gone, the token is invalid).

- [ ] **Step 1: Add request capture to `FakeExecutor`**

In `AuthServiceTests.swift`, add a stored property + assignment to the existing `FakeExecutor` (lines ~22-30) so tests can inspect the DELETE:

```swift
    final class FakeExecutor: RequestExecuting, @unchecked Sendable {
        var routes: [String: (Data, Int)] = [:]
        private(set) var lastBody: Data?
        private(set) var lastRequest: URLRequest?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            if request.url!.path.hasSuffix("auth-with-oauth2") { lastBody = request.httpBody }
            let (data, status) = routes.first { request.url!.path.hasSuffix($0.key) }?.value ?? (Data(), 404)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
```

- [ ] **Step 2: Add a JWT helper that carries an `id` (for `currentUserId`)**

The existing `makeJWT(exp:)` has no `id` claim. Add an overload near it (after line 84):

```swift
    private func makeJWT(id: String, exp: Int) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let h = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        return "\(h).\(b64url(Data("{\"id\":\"\(id)\",\"exp\":\(exp)}".utf8))).sig"
    }
```

- [ ] **Step 3: Write the 4 failing tests**

Add to `AuthServiceTests` (before the closing `}`). The far-future `exp` (1_893_456_000 ≈ 2030) keeps `validToken()` from hitting the network, so the only request is the DELETE. Reuses the existing `refreshService(store:exec:now:)` builder and the `pb_error` fixture.

```swift
    @Test func deleteAccountBuildsAuthedDeleteForTheUserRecord() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let token = makeJWT(id: "u1", exp: 1_893_456_000)
        let store = InMemoryTokenStore(token); let exec = FakeExecutor()
        exec.routes["records/u1"] = (Data(), 204)
        try await refreshService(store: store, exec: exec, now: now).deleteAccount()
        #expect(exec.lastRequest?.httpMethod == "DELETE")
        #expect(exec.lastRequest?.url?.path.hasSuffix("/api/collections/users/records/u1") == true)
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == token)
        #expect(store.token == nil)   // success ends the session
    }

    @Test func deleteAccountAuthRejectionClearsTokenAndThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(id: "u1", exp: 1_893_456_000)); let exec = FakeExecutor()
        exec.routes["records/u1"] = (try fixture("pb_error"), 403)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { try await service.deleteAccount() }
        #expect(store.token == nil)   // dead session → cleared
    }

    @Test func deleteAccountTransientFailureKeepsTokenForRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let kept = makeJWT(id: "u1", exp: 1_893_456_000)
        let store = InMemoryTokenStore(kept); let exec = FakeExecutor()
        exec.routes["records/u1"] = (try fixture("pb_error"), 500)   // hiccup, not a rejection
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { try await service.deleteAccount() }
        #expect(store.token == kept)  // retryable; NOT signed out
    }

    @Test func deleteAccountThrowsNotSignedInWhenNoToken() async throws {
        let service = refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 1_000_000_000))
        await #expect(throws: AuthError.notSignedIn) { try await service.deleteAccount() }
    }
```

- [ ] **Step 4: Run the tests — verify they fail**

Run: `cd GSDKit && swift test --filter AuthServiceTests`
Expected: compile error / FAIL — `deleteAccount` is not a member of `AuthService`.

- [ ] **Step 5: Implement `deleteAccount()`**

In `AuthService.swift`, add after `refresh()` (after line 77):

```swift
    /// Deletes the signed-in user's PocketBase account record (App Store 5.1.1(v)). Requires a live
    /// token. On a confirmed delete — and on a 401/403, where the session is already dead — the
    /// Keychain token is cleared; a transient/network failure leaves it so the user can retry.
    /// The caller MUST erase the user's tasks (SyncEngine.eraseAllRemote) BEFORE this — once the
    /// record is gone the token is invalid and tasks can no longer be removed.
    public func deleteAccount() async throws {
        guard let token = try await validToken() else { throw AuthError.notSignedIn }
        guard let id = currentUserId() else { throw AuthError.notSignedIn }
        let request = client.authedRequest(
            path: "/api/collections/users/records/\(id)", method: "DELETE", token: token)
        do {
            try await client.sendNoContent(request)
        } catch {
            if Self.isAuthRejection(error) { tokenStore.clear() }
            throw error
        }
        tokenStore.clear()
    }
```

- [ ] **Step 6: Run the tests — verify they pass**

Run: `cd GSDKit && swift test --filter AuthServiceTests`
Expected: PASS (all 4 new tests + the existing AuthService tests).

- [ ] **Step 7: Full suite regression + commit**

```bash
cd GSDKit && swift test
git add GSDKit/Sources/GSDSync/AuthService.swift GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift
git commit -m "feat(auth): AuthService.deleteAccount() — authed user-record DELETE (App Store 5.1.1(v))"
```

Expected: full suite green.

---

## Task 2: `SyncCoordinator.eraseRemoteTasks()` (app glue)

**Files:**
- Modify: `App/Sync/SyncCoordinator.swift`

**Why:** Account deletion must erase the user's *server tasks* first, but — unlike `eraseEverywhere` — must NOT wipe local data (the user chooses that separately). This is the remote-only half of `eraseEverywhere`, returning whether the remote is now clear.

- [ ] **Step 1: Add the method**

In `SyncCoordinator.swift`, add next to `eraseEverywhere(store:)` (after line 124):

```swift
    /// Account-deletion step 1: delete only the user's REMOTE tasks (no local wipe — the caller
    /// decides the local fate). Mirrors `eraseEverywhere`'s remote half. Returns true if the remote
    /// is now clear (or there was nothing/no session to erase).
    func eraseRemoteTasks() async -> Bool {
        var result = await engine.eraseAllRemote()
        var tries = 0
        while result.skipped && tries < 5 {
            try? await _Concurrency.Task.sleep(for: .milliseconds(400))
            result = await engine.eraseAllRemote()
            tries += 1
        }
        let ok = result.notSignedIn || (result.error == nil && !result.skipped)
        await refreshStatus()
        return ok
    }
```

- [ ] **Step 2: Build + regression**

```bash
cd GSDKit && swift test
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: tests green; BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sync/SyncCoordinator.swift
git commit -m "feat(sync): SyncCoordinator.eraseRemoteTasks() — remote-only erase for account deletion"
```

---

## Task 3: `SessionStore.deleteAccount(eraseLocalData:)` (app glue)

**Files:**
- Modify: `App/Auth/SessionStore.swift`

**Why:** The orchestrator. Fail-safe ordering: erase remote tasks → delete the account record → **only then** local teardown. Any remote failure aborts WITHOUT touching local data (never strand deleted-local / alive-remote). Mirrors the existing `inProgress`/`lastError` surface so the Settings UI reacts the same way it does for sign-in.

- [ ] **Step 1: Add the method**

In `SessionStore.swift`, add after `signOut()` (after line 92):

```swift
    /// In-app account deletion (App Store 5.1.1(v)). Ordered + fail-safe: erase remote tasks →
    /// delete the account record → ONLY THEN local teardown. A remote failure aborts and leaves
    /// local data untouched (offline-first: never wipe local while the remote account survives).
    func deleteAccount(eraseLocalData: Bool) async {
        inProgress = true; lastError = nil
        defer { inProgress = false }

        // 1. Erase the user's server tasks first (while the token is still valid).
        guard await coordinator?.eraseRemoteTasks() ?? true else {
            lastError = String(localized: "Couldn't reach the server to delete your account. Check your connection and try again.")
            return
        }

        // 2. Delete the account record.
        do {
            try await auth.deleteAccount()
        } catch AuthError.notSignedIn {
            lastError = String(localized: "Your session expired — sign in again to delete your account.")
            signOut()   // clear the dead session so Settings offers sign-in again
            return
        } catch {
            lastError = String(localized: "Couldn't delete your account right now. Check your connection and try again.")
            return
        }

        // 3. Local teardown — only after the remote delete is confirmed.
        if eraseLocalData {
            try? await eraseLocal()
        }
        signOut()
    }
```

- [ ] **Step 2: Build + regression**

```bash
cd GSDKit && swift test
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: tests green; BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Auth/SessionStore.swift
git commit -m "feat(auth): SessionStore.deleteAccount — ordered remote-then-local deletion flow"
```

---

## Task 4: `SettingsView` — Delete Account row + confirmation (app glue)

**Files:**
- Modify: `App/Settings/SettingsView.swift`

**Why:** The entry point. A destructive "Delete Account…" row (signed-in only) opens a single `confirmationDialog` offering the two destructive choices + Cancel — the locked "let the user choose" + "single confirmation" decisions.

- [ ] **Step 1: Add the dialog state**

In `SettingsView.swift`, add to the struct's stored properties (alongside the existing `@Environment`/`@State` declarations near the top of the struct):

```swift
    @State private var showDeleteAccount = false
```

- [ ] **Step 2: Add the destructive row**

In `accountSection`, immediately after the "Sign Out" `Button` block (after its closing `}` at line ~100, still inside `if session.isSignedIn`):

```swift
                Button(role: .destructive) {
                    showDeleteAccount = true
                } label: {
                    Label(String(localized: "Delete Account…"), systemImage: "trash")
                }
                .disabled(session.inProgress)
```

- [ ] **Step 3: Attach the confirmation dialog**

Attach to the `Section` returned by `accountSection` — add the modifier on the `Section(...)`'s closing (the `accountSection` body becomes the `Section { … }.confirmationDialog(…)`):

```swift
        .confirmationDialog(
            String(localized: "Delete your account?"),
            isPresented: $showDeleteAccount,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete & keep tasks on this device"), role: .destructive) {
                _Concurrency.Task { await session.deleteAccount(eraseLocalData: false) }
            }
            Button(String(localized: "Delete & erase everything"), role: .destructive) {
                _Concurrency.Task { await session.deleteAccount(eraseLocalData: true) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This permanently deletes your account and every task synced to it. This can't be undone."))
        }
```

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

Expected: BUILD SUCCEEDED on both.

- [ ] **Step 5: Sim smoke (render only)**

Install + launch on the iPhone 17 Pro sim, open Settings. Expected: signed-out shows the sign-in buttons (no Delete Account); after a (mock or real) sign-in the **Delete Account…** row appears and tapping it shows the dialog with the two destructive choices + Cancel. (Full live deletion is Task 5 — needs a real account + backend.)

- [ ] **Step 6: Commit**

```bash
git add App/Settings/SettingsView.swift
git commit -m "feat(settings): in-app Delete Account row + confirmation (App Store 5.1.1(v))"
```

---

## Task 5: Backend rule, live smoke, resubmission (ops — no code)

**Files:** none. Owner-side PocketBase + App Store Connect steps. **This is the gate that proves the feature end-to-end.**

- [ ] **Step 1: Enable self-deletion on the `users` collection (PocketBase @ api.vinny.io)**

In the PocketBase admin UI → Collections → `users` → API rules → **Delete rule**:

```
@request.auth.id = id
```

(Today it is almost certainly admin-only/empty, so the client DELETE would 403.) Optional defense-in-depth: set the `tasks.owner` relation to **cascade-delete** so a deleted user can never orphan task records.

- [ ] **Step 2: Live smoke on a real device (both paths + abort)**

On a signed build (device or TestFlight), signed into a throwaway account with a couple of synced tasks:
- **Keep path:** Settings → Delete Account… → "Delete & keep tasks on this device" → expect: signed out, the account + its server tasks gone (verify in the web app / PocketBase), **local tasks still present**.
- **Erase path:** sign in again (or a second account) → "Delete & erase everything" → expect: signed out **and** local DB empty.
- **Abort path:** turn on Airplane Mode → Delete Account… → expect the "Couldn't reach the server…" banner, **still signed in, nothing deleted**.

- [ ] **Step 3: Capture the App Review screen recording**

On a physical device, record: sign in with the demo account → Settings → Delete Account… → the full flow to confirmation. Add it (and the demo account creds) to **App Store Connect → App Review Information → Notes**, as the rejection requires for future submissions.

- [ ] **Step 4: Ship + reply to App Review**

Bump the build (`scripts/release.sh patch` or `build`), submit the new iOS build for review, and reply to the rejection message in App Store Connect referencing the recording. (Owner note: reconcile the App Store *version record* — the rejection cited 1.0 (8) vs TestFlight's 1.7.0 (17).) The Catalyst branch inherits this on its next rebase/merge from `main`.

---

## Self-review

- **Spec coverage:** in-app deletion (T1/T3/T4) · let-the-user-choose local fate (T3 `eraseLocalData` + T4 two buttons) · single confirmation (T4) · remote user + server tasks deleted (T1 + T2) · ordered remote-then-local, never-wipe-local-on-failure (T3 guards) · 401/network handling (T1 token rules + T3 catches) · backend `users` delete rule (T5) · iOS+Mac via shared code (all tasks) · resubmission recording (T5). All spec sections map to a task.
- **Placeholder scan:** none — every code step shows complete code; every command shows expected output.
- **Type consistency:** `deleteAccount()` (T1) is the same symbol called in `SessionStore.deleteAccount` (T3); `eraseRemoteTasks()` (T2) is the same symbol called in T3; `session.deleteAccount(eraseLocalData:)` (T3) matches the T4 call sites; `FakeExecutor.lastRequest` / `makeJWT(id:exp:)` defined and used within T1; `client.authedRequest`/`sendNoContent` and `SyncResult.skipped/notSignedIn/error` match the referenced source.
