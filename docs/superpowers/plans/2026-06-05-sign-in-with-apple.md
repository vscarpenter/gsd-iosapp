# Sign in with Apple Implementation Plan

> **⚠️ SUPERSEDED (2026-06-06 → reworked 2026-06-07).** This plan describes the **native** `SignInWithAppleButton`/`ASAuthorizationController` sheet. The owner pivoted to **Option A** (unify iOS+web on the PocketBase **web** OAuth flow with a Services-ID `client_id`) because adding Apple to the web app too reintroduces the multi-`client_id` conflict (pocketbase#6151). The native code below was merged @ `5b97dbf` then **retired**: Apple now rides `signIn(provider:"apple")` like Google, GitHub was wired alongside it, and `AuthService.signInWithApple`/`SessionStore.signInWithApple`/the `applesignin` entitlement were deleted (`AppleIdentity` kept). See `docs/2026-06-06-sign-in-with-apple-web-oauth-setup.md` for the live setup. Kept for history only — do not execute.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Sign in with Apple — the system sheet returns an authorization code that is exchanged with the existing PocketBase `auth-with-oauth2` endpoint, yielding the same JWT/session as Google.

**Architecture:** A new short `AuthService.signInWithApple(authorizationCode:)` reuses `PocketBaseClient.authWithOAuth2(provider:"apple")` (no web presenter, no `state`). The SwiftUI `SignInWithAppleButton` is the "presenter" — its credential feeds `SessionStore.signInWithApple`. A pure `AppleIdentity.isRelayEmail` helper drives a gentle "Hide My Email" note. Backend + Apple Developer portal setup is owner work (spec §9), not in this plan.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, GRDB-free `GSDSync` package, SwiftUI + AuthenticationServices, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-06-05-sign-in-with-apple-design.md`

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `GSDKit/Sources/GSDSync/AppleIdentity.swift` | Create | Pure `isRelayEmail` helper |
| `GSDKit/Tests/GSDSyncTests/AppleIdentityTests.swift` | Create | Truthtable for `isRelayEmail` |
| `GSDKit/Sources/GSDSync/AuthService.swift` | Modify | Add `signInWithApple(authorizationCode:codeVerifier:redirectURL:)` |
| `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift` | Modify | Add 3 Apple tests (reuse existing fakes/fixtures) |
| `App/Auth/SessionStore.swift` | Modify | `signInWithApple(authorizationCode:)` + `usingRelayEmail` flag |
| `App/GSD.entitlements` | Modify | Add `com.apple.developer.applesignin` |
| `App/Settings/SettingsView.swift` | Modify | `SignInWithAppleButton` + convergence note + relay hint |

---

## Task 1: `AppleIdentity.isRelayEmail` (pure helper, GSDSync)

**Files:**
- Create: `GSDKit/Sources/GSDSync/AppleIdentity.swift`
- Test: `GSDKit/Tests/GSDSyncTests/AppleIdentityTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GSDKit/Tests/GSDSyncTests/AppleIdentityTests.swift`:

```swift
import Testing
@testable import GSDSync

struct AppleIdentityTests {
    @Test func relayAddressIsDetected() {
        #expect(AppleIdentity.isRelayEmail("abc123@privaterelay.appleid.com"))
    }
    @Test func relayDetectionIsCaseInsensitive() {
        #expect(AppleIdentity.isRelayEmail("ABC@PrivateRelay.AppleID.Com"))
    }
    @Test func realEmailsAreNotRelay() {
        #expect(!AppleIdentity.isRelayEmail("vscarpenter@gmail.com"))
        #expect(!AppleIdentity.isRelayEmail("me@vinny.io"))
    }
    @Test func lookalikeDomainIsNotRelay() {
        #expect(!AppleIdentity.isRelayEmail("me@privaterelay.appleid.com.evil.com"))
    }
    @Test func emptyOrMalformedIsNotRelay() {
        #expect(!AppleIdentity.isRelayEmail(""))
        #expect(!AppleIdentity.isRelayEmail("privaterelay.appleid.com"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter AppleIdentityTests`
Expected: FAIL — `cannot find 'AppleIdentity' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `GSDKit/Sources/GSDSync/AppleIdentity.swift`:

```swift
import Foundation

/// Apple Sign In identity helpers (design §3). Pure — no dependencies. `public` because the App's
/// `SessionStore` reads it to drive the relay-email note.
public enum AppleIdentity {
    /// True when `email` is an Apple "Hide My Email" private relay address
    /// (`…@privaterelay.appleid.com`), case-insensitive. A relay sign-in lands a *separate*
    /// PocketBase account — it does not converge by email with the web app (§8.4).
    public static func isRelayEmail(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@privaterelay.appleid.com")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter AppleIdentityTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/AppleIdentity.swift GSDKit/Tests/GSDSyncTests/AppleIdentityTests.swift
git commit -m "feat(auth): AppleIdentity.isRelayEmail helper for Hide My Email detection"
```

---

## Task 2: `AuthService.signInWithApple` (GSDSync)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/AuthService.swift` (add method after `signIn`, ~line 35)
- Test: `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift` (add tests, reuse existing `FakePresenter`/`InMemoryTokenStore`/`FakeExecutor`/`fixture`)

- [ ] **Step 1: Write the failing tests**

In `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift`, add these three tests inside the `AuthServiceTests` struct (e.g. just after `unknownProviderThrows`, before the `makeJWT` helper). They reuse the file's existing `FakePresenter`, `InMemoryTokenStore`, `FakeExecutor`, and `fixture(_:)`:

```swift
    private func appleService(store: TokenStore, exec: FakeExecutor) -> AuthService {
        AuthService(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                    presenter: FakePresenter(.failure(AuthError.cancelled)),   // never used by the Apple path
                    tokenStore: store, config: .live)
    }

    @Test func appleSignInStoresTokenAndSendsAppleProvider() async throws {
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        exec.routes["auth-with-oauth2"] = (try fixture("auth_with_oauth2"), 200)
        let result = try await appleService(store: store, exec: exec).signInWithApple(authorizationCode: "APPLE_CODE")
        #expect(result.record.email == "v@example.com")
        #expect(store.token == "header.payload.signature")
        let sent = try JSONDecoder().decode([String: String].self, from: #require(exec.lastBody))
        #expect(sent["provider"] == "apple")
        #expect(sent["code"] == "APPLE_CODE")
        #expect(sent["codeVerifier"] == "")
        #expect(sent["redirectURL"] == "")
    }

    @Test func appleSignInEmptyCodeThrowsAndStoresNothing() async throws {
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        await #expect(throws: AuthError.missingCode) {
            _ = try await appleService(store: store, exec: exec).signInWithApple(authorizationCode: "")
        }
        #expect(store.token == nil)
    }

    @Test func appleSignInBackendErrorSurfacesAndStoresNothing() async throws {
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        exec.routes["auth-with-oauth2"] = (try fixture("pb_error"), 400)
        await #expect(throws: PocketBaseError.self) {
            _ = try await appleService(store: store, exec: exec).signInWithApple(authorizationCode: "APPLE_CODE")
        }
        #expect(store.token == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd GSDKit && swift test --filter AuthServiceTests`
Expected: FAIL — `value of type 'AuthService' has no member 'signInWithApple'`.

- [ ] **Step 3: Write minimal implementation**

In `GSDKit/Sources/GSDSync/AuthService.swift`, add this method immediately after `signIn(provider:)` (after line 35, before `signOut`):

```swift
    /// Native Sign in with Apple (design §2). The system sheet already performed the OAuth interaction;
    /// we only exchange the returned `authorizationCode` at PocketBase's `auth-with-oauth2`. No
    /// `auth-methods` fetch, no `state`, no web presenter. `codeVerifier`/`redirectURL` default empty —
    /// the native handshake has no PKCE verifier and no web redirect (distinct from the web flow's
    /// `AuthConfig.redirectURI`); confirm exact values at the live gate (§8).
    public func signInWithApple(authorizationCode: String,
                                codeVerifier: String = "",
                                redirectURL: String = "") async throws -> AuthResult {
        guard !authorizationCode.isEmpty else { throw AuthError.missingCode }
        let result = try await client.authWithOAuth2(
            provider: "apple", code: authorizationCode, codeVerifier: codeVerifier, redirectURL: redirectURL)
        tokenStore.save(result.token)
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd GSDKit && swift test --filter AuthServiceTests`
Expected: PASS (all AuthServiceTests, including the 3 new Apple tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/AuthService.swift GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift
git commit -m "feat(auth): AuthService.signInWithApple exchanges Apple code with PocketBase"
```

---

## Task 3: `SessionStore.signInWithApple` + relay flag (App)

**Files:**
- Modify: `App/Auth/SessionStore.swift`

No unit test — `SessionStore` is `@MainActor` app glue verified by build + the live gate, matching the existing `signIn`/`signOut` precedent (the testable logic it calls is covered in Tasks 1–2).

- [ ] **Step 1: Add the relay flag property**

In `App/Auth/SessionStore.swift`, add a new published property next to the others (after `private(set) var lastError: String?`, ~line 14):

```swift
    /// True when the last sign-in returned an Apple "Hide My Email" relay address — gates the
    /// "separate account" hint (design §3). Reset on sign-out.
    private(set) var usingRelayEmail = false
```

- [ ] **Step 2: Add the Apple sign-in method**

In the same file, add this method immediately after `signIn(provider:)` (after its closing brace, ~line 45):

```swift
    /// Native Sign in with Apple — `SettingsView` passes the credential's authorization code (or `""`
    /// if extraction failed, which surfaces the generic banner). Mirrors `signIn(provider:)`: silent on
    /// cancel, generic banner otherwise. Sets `usingRelayEmail` for the §3 hint.
    func signInWithApple(authorizationCode: String) async {
        inProgress = true; lastError = nil
        defer { inProgress = false }
        do {
            let result = try await auth.signInWithApple(authorizationCode: authorizationCode)
            email = result.record.email
            usingRelayEmail = AppleIdentity.isRelayEmail(result.record.email)
            UserDefaults.standard.set(result.record.email, forKey: emailKey)
            coordinator?.start(trigger: .signIn)   // first sign-in seeds + pulls the user's existing tasks
        } catch AuthError.cancelled {
            // user dismissed — silent, stay signed out, no banner
        } catch {
            lastError = String(localized: "Sign-in failed. Please try again.")
        }
    }
```

- [ ] **Step 3: Reset the flag on sign-out**

In `signOut()`, add `usingRelayEmail = false` alongside the other resets:

```swift
    func signOut() {
        auth.signOut()
        email = nil
        usingRelayEmail = false
        UserDefaults.standard.removeObject(forKey: emailKey)
        coordinator?.signedOut()   // tear down + reset cursor; local tasks kept
    }
```

- [ ] **Step 4: Verify GSDSync logic still compiles**

Run: `cd GSDKit && swift test`
Expected: PASS (full suite; confirms `AppleIdentity` + `signInWithApple` are public and consumable). The App target builds in Task 4.

- [ ] **Step 5: Commit**

```bash
git add App/Auth/SessionStore.swift
git commit -m "feat(auth): SessionStore.signInWithApple wires the Apple credential + relay flag"
```

---

## Task 4: Entitlement + Settings UI (App)

**Files:**
- Modify: `App/GSD.entitlements`
- Modify: `App/Settings/SettingsView.swift`

- [ ] **Step 1: Add the Sign in with Apple entitlement**

Edit `App/GSD.entitlements` — add the key inside the existing `<dict>` (alongside `application-groups`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.dev.vinny.gsd</string>
    </array>
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Import AuthenticationServices + read color scheme in SettingsView**

In `App/Settings/SettingsView.swift`, add the import at the top (after `import SwiftUI`, line 1):

```swift
import AuthenticationServices
```

And add a color-scheme environment read alongside the other `@Environment` lines (after line 13):

```swift
    @Environment(\.colorScheme) private var colorScheme
```

- [ ] **Step 3: Add the relay hint to the signed-in branch**

In `accountSection`, inside the `if session.isSignedIn {` branch, add the hint right after the existing "Signed in" `LabeledContent` (after line 65, before the `if let last = sync.lastSync` block):

```swift
                if session.usingRelayEmail {
                    Text(String(localized: "Signed in with a private relay email — this is a separate account from your web tasks."))
                        .font(.footnote)
                        .foregroundStyle(Surface.ink3)
                }
```

- [ ] **Step 4: Add the Apple button + convergence note to the signed-out branch**

In `accountSection`, replace the existing signed-out `else { … }` branch (the Google-only block, ~lines 93–104) with this — the Google button is unchanged; the Apple button and note are added below it:

```swift
            } else {
                Button {
                    _Concurrency.Task { await session.signIn(provider: "google") }
                } label: {
                    if session.inProgress {
                        ProgressView()
                    } else {
                        Label(String(localized: "Sign in with Google"), systemImage: "person.crop.circle")
                    }
                }
                .disabled(session.inProgress)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        // Native flow returns the authorization code; "" routes to the generic banner.
                        let code = (auth.credential as? ASAuthorizationAppleIDCredential)
                            .flatMap(\.authorizationCode)
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        _Concurrency.Task { await session.signInWithApple(authorizationCode: code) }
                    case .failure(let error):
                        if case ASAuthorizationError.canceled = error { return }   // user dismissed — silent
                        _Concurrency.Task { await session.signInWithApple(authorizationCode: "") }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(session.inProgress)

                Text(String(localized: "To sync with the web app and your other devices, sign in with the same email you use there."))
                    .font(.footnote)
                    .foregroundStyle(Surface.ink3)
            }
```

- [ ] **Step 5: Regenerate the project and build both targets**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: both `** BUILD SUCCEEDED **`. (XcodeGen preserves the `CODE_SIGN_ENTITLEMENTS: App/GSD.entitlements` reference; the entitlement content is what changed.)

- [ ] **Step 6: Commit**

```bash
git add App/GSD.entitlements App/Settings/SettingsView.swift GSD.xcodeproj
git commit -m "feat(auth): native Sign in with Apple button + entitlement + relay note"
```

---

## Task 5: Final verification

- [ ] **Step 1: Full unit suite**

Run: `cd GSDKit && swift test`
Expected: PASS — full suite green (prior count + 8 new tests: 5 AppleIdentity, 3 AuthService Apple).

- [ ] **Step 2: Confirm both app builds are clean**

Run the two `xcodebuild … build` commands from Task 4 Step 5 if not already green this session.
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify the entitlement landed in the generated project**

Run: `grep -n "applesignin" App/GSD.entitlements`
Expected: the `com.apple.developer.applesignin` key is present.

---

## Out of scope / owner handoff (not code tasks — spec §9)

These gate *runtime success* and the live gate, but not the merge of this code:

1. **Apple Developer portal:** enable the *Sign in with Apple* capability on App ID `dev.vinny.gsd`; create a *Sign in with Apple* Key (.p8); record Key ID + Team ID; regenerate the provisioning profile.
2. **PocketBase admin → Auth providers → Apple:** enable; set `client_id` = bundle ID `dev.vinny.gsd`; provide App ID / Team ID / Key ID / .p8.
3. **Live gate (real device):** native sheet appears; real-email sign-in converges with the Google account; Hide-My-Email shows the relay note + lands a separate account; token persists across cold launch. Confirm the native exchange's `codeVerifier`/`redirectURL` (spec §8) — if the backend needs non-empty values, pass them at the `SessionStore.signInWithApple` → `AuthService.signInWithApple` call (one-line change).

Until steps 1–2 are done, the Apple button builds and appears but sign-in fails with the generic banner (PocketBase has no `apple` provider yet) — expected.
