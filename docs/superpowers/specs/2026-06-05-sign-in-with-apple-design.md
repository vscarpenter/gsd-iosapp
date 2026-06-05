# Sign in with Apple — Design

- **Date:** 2026-06-05
- **Status:** Approved for planning
- **Authority:** `spec.md` §8 (Authentication), §13 (App Store); resolves the §8.4 cross-provider identity edge for the Apple provider.
- **Scope:** Add native Sign in with Apple to the iOS app. Apple only (GitHub not in scope). No change to the existing Google flow. No backend code authored here — the backend + Apple Developer portal steps are the owner's, captured as a handoff checklist.

---

## 1. Goal & context

App Store Guideline 4.8 requires Sign in with Apple because the app offers third-party social login (Google). Today the app has **no** Apple sign-in: `App/GSD.entitlements` holds only `application-groups`, and `SettingsView` wires only a "Sign in with Google" button. This is the one hard blocker for App Store submission.

The existing auth (`GSDSync`) is a hand-built **PocketBase OAuth2-PKCE flow over a web session** (`ASWebAuthenticationSession`). `AuthService.signIn(provider:)` runs the entire handshake: fetch `users/auth-methods`, find the provider, present the web auth URL, validate `state`, exchange the code at `users/auth-with-oauth2`, store the token. Google works because PocketBase brokers the OAuth; the app never talks to Google directly.

Apple cannot reuse that path as-is:

- App Review + HIG expect the **native** Sign in with Apple sheet (`ASAuthorizationController` / `SignInWithAppleButton`), not a Safari web login. A web-based Apple login is a known rejection risk — which defeats the purpose.
- The native sheet inverts the handshake: the **system** performs the OAuth interaction and returns an `authorizationCode`. The app does not drive `auth-methods` / `state` / a web redirect for Apple.

## 2. Approach

**Native `ASAuthorizationController` → authorization-code exchange with PocketBase.**

1. The SwiftUI `SignInWithAppleButton(.signIn)` presents the system sheet and returns an `ASAuthorizationAppleIDCredential`.
2. The app extracts the `authorizationCode` (ASCII `Data` → `String`) and hands it to a new, shorter `AuthService` entry point.
3. That entry point POSTs the code to the **existing** `PocketBaseClient.authWithOAuth2(provider: "apple", code:, codeVerifier:, redirectURL:)` endpoint. PocketBase exchanges the code with Apple server-side and returns a normal PocketBase JWT + user record — **identical in shape to the Google result**, so token storage, refresh (`auth-refresh`), sync seeding, and the session model all work unchanged.

### Why the authorization code (not the identity token)

PocketBase supports only the OAuth2 **authorization-code** flow, not direct ID-token auth ([pocketbase/pocketbase#6463](https://github.com/pocketbase/pocketbase/issues/6463)). The native credential also carries an `identityToken` (a signed JWT), but using it would require custom backend code. The authorization-code path reuses the client method we already have.

### The `client_id` reconciliation (the key backend fact)

Apple requires a **native app to use its Bundle ID as `client_id`**, while web uses a separate Services ID; PocketBase allows only one `client_id` per provider ([pocketbase/pocketbase#6151](https://github.com/pocketbase/pocketbase/issues/6151)). Normally a conflict — but the owner's **web app uses Google/GitHub, not Apple**, so PocketBase's Apple provider is configured with the iOS bundle ID `dev.vinny.gsd` and there is no conflict.

### Alternatives rejected

- **Web OAuth (reuse `signIn(provider:"apple")`):** minimal iOS code, but Safari login instead of the native sheet → App Review rejection risk.
- **Send the Apple identity token to the backend:** unsupported by PocketBase out of the box; requires custom backend hooks.

## 3. Identity convergence & the relay-email edge

The §8.4 model is **email-keyed convergence** (resolved previously): signing in with the same verified email as the web app lands the user on the same PocketBase account and shared task set.

Native Sign in with Apple offers **"Hide My Email,"** which returns a private relay address (`…@privaterelay.appleid.com`). A relay email does not match the user's Google/web email → a **separate** PocketBase account with its own tasks. The app cannot override Apple's choice; the only lever is honest copy (consistent with the privacy-first, truthful-UI principle):

- A calm one-line note near the Apple button, always shown: *"To sync with the web app and your other devices, use the same email you sign in with there."*
- After sign-in, if the returned email is a relay, a quiet hint in the account row: *"Signed in with a private relay email — this is a separate account from your web tasks."*

Apple not returning a user **name** has caused rejections for apps that require it ([pocketbase/pocketbase#7090](https://github.com/pocketbase/pocketbase/issues/7090)); irrelevant here — GSD uses only the email.

## 4. Components

### GSDSync (pure, unit-tested)

- **`AuthService.signInWithApple(authorizationCode:) async throws -> AuthResult`** — new entry point. Calls `client.authWithOAuth2(provider: "apple", code: authorizationCode, codeVerifier:, redirectURL:)`, saves the returned token to the `TokenStore`, returns the `AuthResult`. Distinct from `signIn(provider:)` — no `auth-methods` fetch, no `state` validation, no web presenter (the system already performed the interaction). Testable against the existing fixture `RequestExecuting` seam.
- **`AppleIdentity.isRelayEmail(_:) -> Bool`** — pure helper; `true` when the email's host is `privaterelay.appleid.com` (case-insensitive). Drives the relay note. No new dependency.

### App layer (manual/live-tested, mirroring `LiveWebAuthPresenter`)

- **`SettingsView` account section** — add the HIG-compliant SwiftUI `SignInWithAppleButton(.signIn, onRequest:onCompletion:)` below the Google button (signed-out state only), styled for light/dark. `onRequest` sets `requestedScopes = [.email]`. `onCompletion` extracts `authorizationCode` from the `ASAuthorizationAppleIDCredential` and calls `SessionStore.signInWithApple(authorizationCode:)`. The always-on convergence note sits beneath the buttons.
- **`SessionStore.signInWithApple(authorizationCode:)`** — `@MainActor` wrapper: sets `inProgress`, calls `auth.signInWithApple(...)`, on success sets `email`, caches it, calls `coordinator?.start(trigger: .signIn)` (same as Google), and sets a new published `usingRelayEmail` flag via `AppleIdentity.isRelayEmail(result.record.email)`. User-cancel is silent; other errors set `lastError`.
- **`usingRelayEmail: Bool`** on `SessionStore` (reset on sign-out) gates the account-row relay hint.

### Entitlements & project config

- **`App/GSD.entitlements`** — add `com.apple.developer.applesignin = ["Default"]`. Hand-maintained file referenced by `project.yml` (`CODE_SIGN_ENTITLEMENTS: App/GSD.entitlements`); **not** XcodeGen-generated, so editing it directly is safe. Run `xcodegen generate` afterward and confirm the reference survives.
- No other `project.yml` change required.

## 5. Data flow

```
SignInWithAppleButton tap
  → system Sign in with Apple sheet (Face ID / Touch ID)
  → ASAuthorizationAppleIDCredential { authorizationCode, identityToken, email? }
  → SessionStore.signInWithApple(authorizationCode:)
  → AuthService.signInWithApple(authorizationCode:)
  → PocketBaseClient.authWithOAuth2(provider:"apple", code:, codeVerifier:, redirectURL:)
  → PocketBase verifies the code with Apple (server-side) → JWT + user record
  → TokenStore.save(token); email cached in UserDefaults
  → SyncCoordinator.start(.signIn)  // seeds + pulls the account's existing tasks
  → AppleIdentity.isRelayEmail(record.email) → usingRelayEmail flag → relay hint
```

## 6. Error handling

| Case | Behavior |
|---|---|
| User cancels the sheet (`ASAuthorizationError.canceled`) | Silent; stay signed out; no banner (mirrors the Google cancel path) |
| Missing/blank `authorizationCode` from the credential | Typed `AuthError` → generic "Sign-in failed. Please try again." banner |
| Exchange HTTP/decoding failure (incl. backend Apple provider not yet configured) | Existing `lastError` banner; token not stored; remains signed out |
| Token refresh later | Unchanged — PocketBase issues the same JWT; existing `auth-refresh` path applies |

## 7. Testing

**Unit (GSDSync, `swift test`, no network):**
- `signInWithApple` success: given a fixture `auth-with-oauth2` response, returns the `AuthResult` and stores the token in the in-memory `TokenStore`.
- `signInWithApple` failure: non-2xx from the executor surfaces a typed `PocketBaseError`; token is **not** stored.
- `AppleIdentity.isRelayEmail`: truthtable — relay host true; real emails (gmail, custom domains) false; case-insensitive; malformed input false.

**Live gate (owner, real device — requires entitlement + backend live):**
- Native sheet appears (not a web page).
- Real-email sign-in lands on the **same** account as Google (web tasks appear after pull).
- "Hide My Email" → relay note shown; lands a **separate** account.
- Token persists across a cold launch; Sign Out clears it and `usingRelayEmail`.

## 8. Integration risk to validate at the live gate

The exact `codeVerifier` and `redirectURL` values the **native** exchange needs are confirmed live. PocketBase's authorization-code flow was designed around web redirects; for a native Apple code the verifier is likely empty and the `redirectURL` either empty or a specific value the backend expects. These are **distinct from** the web flow's `AuthConfig.redirectURI` (the `…/ios-oauth-redirect/` bounce page), which does not apply to the native handshake. `AuthService.signInWithApple` therefore takes its own `codeVerifier`/`redirectURL` parameters with empty-string defaults, rather than reusing `AuthConfig.redirectURI` — tuning them at the live gate is a one-line change, not a redesign. This is the single open integration detail, validated the same way the rest of the hand-built PocketBase client was validated against the live backend.

## 9. Handoff checklist (owner — outside this codebase)

1. **Apple Developer portal:** enable the *Sign in with Apple* capability on App ID `dev.vinny.gsd`; create a *Sign in with Apple* **Key (.p8)**, record Key ID + Team ID; regenerate the app's provisioning profile so the new entitlement is included.
2. **PocketBase admin → Auth providers → Apple:** enable; set `client_id` = bundle ID `dev.vinny.gsd`; provide App ID / Team ID / Key ID / .p8 so PocketBase can generate the client secret.
3. At the live gate, confirm the native exchange params (§8) and that `AuthResult.record.email` carries the expected address (real vs. relay).

## 10. Out of scope

- GitHub sign-in (PRD §6.17 lists it; deferred by explicit decision).
- Any change to the Google web flow.
- Backend code, Apple Developer portal automation, or provisioning (owner-owned, §9).
- Account-linking on the backend (§8.4 option (a)) — convergence stays email-keyed.
