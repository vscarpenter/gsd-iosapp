# Phase 5b — Auth + Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the provider-agnostic auth + transport layer — a hand-built `URLSession` `PocketBaseClient` (auth-methods / auth-with-oauth2 / auth-refresh + an authed-request helper), a **stateful-PKCE** `AuthService` over `WebAuthPresenting`/`TokenStore` seams, and the live App edge (`ASWebAuthenticationSession` + Keychain + a Settings Account section) — wired **Google end-to-end first**, with the live round-trip gating merge.

**Architecture:** Mirrors Phase 4's `ReminderScheduling` seam. `GSDSync` (Foundation-only, depends `GSDModel`) holds the client, auth models, a JWT-`exp` helper, and the `AuthService` orchestration — all unit-tested via an injected request-executor + fixtures (grounded in the **captured** `auth-methods`) and fake seams. The App provides `LiveWebAuthPresenter` (ASWebAuthenticationSession), `KeychainTokenStore` (Security, plain item), a `@MainActor @Observable` `SessionStore`, and the Account UI. The stateful PKCE flow holds the per-attempt `{state, codeVerifier}` from **one** `auth-methods` fetch through the code exchange.

**Tech Stack:** Swift 6, `Foundation`/`URLSession` (GSDSync), `AuthenticationServices` + `Security` + SwiftUI (App), Swift Testing (`@Test`/`#expect`/`#require`), `xcodebuild`+simctl, `xcodegen`.

**Builds on (Phases 0–5a, `main` at `phase-5a-sync-foundation`):**
- `GSDSync` (Foundation-only, depends `GSDModel`): 5a units (`PocketBaseTaskRecord`, `WireDate`, `TaskWireMapper`, `LWW` — all internal). 5b adds the client + auth here; stays Foundation-only + `GSDModel`-only.
- `GSDStore`: `DeviceIdentity`, `SyncQueue` (5c, not used here).
- App: `GSDApp` (`@State store`, `.task` launch hooks, injected deps — extend this for the session), `SettingsView` (`Form` of `Section`s: Appearance/Archive/Data&Storage/Notifications/About — add **Account**), the `ReminderScheduling` protocol + `LiveReminderScheduler` **seam precedent** (5b mirrors it exactly).
- `project.yml` (XcodeGen source of truth; `GENERATE_INFOPLIST_FILE: NO`, `info.path: App/Info.plist`) — add the `gsd` URL scheme.

**Reference:** spec `docs/specs/2026-05-30-phase-5b-auth-transport.md` (Groups A–C, A49–A56); product spec `spec.md` §7–8; the captured `auth-methods` response (PocketBase ≥0.23, `oauth2.providers[]`).

---

## Conventions locked by this plan (read first)

1. **`GSDSync` stays Foundation-only + `GSDModel`-only.** The client uses only `URLSession`/`Foundation`. **NO `AuthenticationServices`, NO `Security`, NO `GSDStore`, NO SwiftUI** in the package — `ASWebAuthenticationSession` + Keychain live in the App behind the `WebAuthPresenting`/`TokenStore` protocols (the Phase-4 `ReminderScheduling` seam, applied to auth).
2. **Stateful PKCE — PROBE-VERIFIED (17/17).** Exactly **one `auth-methods` fetch per `signIn`**; hold that fetch's `{state, codeVerifier, redirectURL}` through the exchange; **validate the returned `state`** (CSRF); the **redirect URI must match exactly** between the `authURL` and `authWithOAuth2`. **Never cache `AuthMethods` across attempts** (a stale `codeVerifier` fails PKCE live; the fake presenter masks it — so the test asserts the threaded verifier).
3. **Token refresh = extend a still-valid JWT — PROBE-VERIFIED.** Decode `exp` from the JWT payload (base64url + padding); refresh **proactively** when within a skew (60s) of expiry; an **unparseable or expired** token → re-auth (PocketBase has **no** long-lived refresh token).
4. **Redirect config is injected (`AuthConfig`).** `callbackScheme = "gsd"`, `redirectURI = "https://api.vinny.io/ios-oauth-redirect/"` (LIVE — the owner set up the authorized redirect URI + bounce page and confirmed it redirects to `gsd://oauth-callback`). `baseURL = "https://api.vinny.io"`. The **same `redirectURI`** builds the `authURL` AND is sent to `authWithOAuth2`.
5. **`authURL` redirect-append = `encodeURIComponent`-equivalent — PROBE-VERIFIED.** Allowed set = alphanumerics + `-_.!~*'()`; everything else (incl. `:` `/`) percent-encoded. The captured `authURL` ends with `&redirect_uri=`; append the encoded redirect there.
6. **Plain Keychain item, NO access group.** The shared access group (§8.3) needs a team/app-ID-prefix entitlement + an actual extension — both arrive in **Phase 6**. Using a plain item in 5b avoids the signing wall and the no-`DEVELOPMENT_TEAM`-in-commits collision.
7. **Cancel vs. presentation failure.** `LiveWebAuthPresenter`: completion error `ASWebAuthenticationSessionError.canceledLogin` → throw `AuthError.cancelled` (silent — `SessionStore` returns to signed-out, no error banner). `session.start()` returning `false` / no presentation anchor → throw `AuthError.presentationFailed` (a surfaced error, NOT swallowed as cancel).
8. **Fixtures grounded in the captured `auth-methods`.** The `auth-with-oauth2` success body + error body are **best-effort** (no real token exchange is possible without an interactive Google sign-in) → flagged to **reconcile at the live round-trip** (capture the real exchange response; specifically confirm whether `state` is required in the POST body).
9. **`SessionStore` is `@MainActor @Observable`** (the `TaskStore` precedent). Auth UI-state (`signedIn`/`email`/`inProgress`/`error`) lives there, **never** in the pure `AuthService`.
10. **`GSDModel.Task` shadows Swift Concurrency's `Task`** — use `_Concurrency.Task { }` for any task closure (none needed in the pure code; `AuthService` methods are `async` and awaited).
11. **DoD — do NOT merge on unit-green.** A green fixture suite proves self-consistency, not working sign-in. **A56 (the live Google round-trip against `api.vinny.io`) gates merge** — built code stays on-branch (Account UI reachable only for testing) until the owner confirms the real flow + §8.4(c) email convergence.
12. **Inject time + the request-executor + seams** for determinism. `ASWebAuthenticationSession` / Keychain / SwiftUI are **build + manual** (Group C), never in `swift test`.

---

## Probe Results (run before this plan shipped; folded in — `/tmp/p5b-probe/probe.swift`, 17/17 PASS)

- **JWT `exp` (5):** base64url decode (with padding) of the payload segment; `exp` → `Date`; single-/two-segment tokens → nil; `needsRefresh` true within 60s skew, false for far-future, true for unparseable.
- **Redirect encoding (3):** `encodeURIComponent`-equivalent (`https://api.vinny.io/ios-oauth-redirect/` → `https%3A%2F%2Fapi.vinny.io%2Fios-oauth-redirect%2F`, keeping `.`/`-`); appended `authURL` is a valid `URL`; `redirect_uri=` populated.
- **Callback parse (2):** `code`+`state` extracted from `gsd://oauth-callback?...`; an `error=` callback yields no `code`.
- **auth-methods decode (5):** the modern `oauth2.providers[]` decodes (dual `authURL`/`authUrl` keys + extra `password`/`mfa`/`otp`/`authProviders` blocks tolerated); 2 providers; google `codeVerifier` + `S256` read; github second.

The real `auth-with-oauth2`/`auth-refresh` response bodies, `ASWebAuthenticationSession`, Keychain, and SwiftUI are **confirm-at-build / live-round-trip** — not `/tmp`-probeable.

---

## File Structure

```
GSDKit/Sources/GSDSync/
├─ PocketBaseError.swift     # A1: typed error enum
├─ AuthModels.swift          # A1: AuthMethods · OAuthProvider · AuthResult · AuthRecord (Decodable)
├─ JWT.swift                 # A2: exp decode (base64url) + expiresWithin(skew, now)
├─ PocketBaseClient.swift    # A3: RequestExecuting seam + client (authMethods/authWithOAuth2/authRefresh
│                            #     + authedRequest helper); error mapping
├─ AuthSeams.swift           # B1: WebAuthPresenting + TokenStore protocols + AuthConfig + AuthError
└─ AuthService.swift         # B1/B2: stateful PKCE orchestration (signIn/signOut/validToken/refresh)

GSDKit/Tests/GSDSyncTests/
├─ AuthModelsTests.swift     # A1
├─ JWTTests.swift            # A2
├─ PocketBaseClientTests.swift # A3 (fake RequestExecuting + fixtures)
├─ AuthServiceTests.swift    # B1/B2 (FakeWebAuthPresenter + InMemoryTokenStore, defined in-file)
└─ Fixtures/
   ├─ auth_methods.json      # A1 (from the captured response, sanitized)
   ├─ auth_with_oauth2.json  # A3 (best-effort; reconcile live)
   └─ pb_error.json          # A3 (PocketBase 400 error body)

App/Auth/
├─ LiveWebAuthPresenter.swift # C1: ASWebAuthenticationSession (WebAuthPresenting)
├─ KeychainTokenStore.swift   # C1: Security plain item (TokenStore)
└─ SessionStore.swift         # C2: @MainActor @Observable
App/Settings/SettingsView.swift # C2: + Account section (MODIFIED)
App/GSDApp.swift                # C2: construct + inject AuthService/SessionStore (MODIFIED)
project.yml                     # C1: app→GSDSync dependency (MODIFIED → xcodegen generate).
                                #     NO Info.plist/URL-scheme change — ASWebAuthenticationSession
                                #     intercepts its callbackURLScheme itself.
```

**Sequencing:** A (client/models/JWT) → B (AuthService) are `GSDSync` + `swift test`, fully self-contained. C (live edge + Account UI) is App, build + simctl-render. The **live Google round-trip (A56)** is a MANUAL gate after C — it needs the owner's interactive sign-in — and **gates the merge**. Run package tests from `GSDKit/`: `swift test --filter GSDSyncTests`.

**Access levels (note):** unlike 5a (all-internal), 5b's App edge consumes `GSDSync`, so the consumed types are **`public`** (`PocketBaseError`, `PocketBaseClient`, `AuthConfig`, `WebAuthPresenting`, `TokenStore`, `AuthService`, `AuthError`, `AuthResult`, `AuthRecord`); internal helpers (`AuthMethods`, `OAuthProvider`, `JWT`, `RequestExecuting`, `PBErrorEnvelope`, `URLSessionExecutor`) stay **internal**. The app→`GSDSync` `project.yml` dependency (deferred in 5a) is added in Group C.

---

## Group A — `PocketBaseClient` + auth models + JWT (`GSDSync`, `swift test`)

> Foundation-only. Fixtures grounded in the captured `auth-methods`. Run: `cd GSDKit && swift test --filter GSDSyncTests`. Maps **A49/A50**. PROBE-VERIFIED (17/17).

### Task A1: Auth models + `PocketBaseError` + the captured `auth-methods` fixture

**Files:**
- Create: `GSDKit/Sources/GSDSync/PocketBaseError.swift`
- Create: `GSDKit/Sources/GSDSync/AuthModels.swift`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/auth_methods.json`
- Test: `GSDKit/Tests/GSDSyncTests/AuthModelsTests.swift`

- [ ] **Step 1: Create the fixture** `GSDKit/Tests/GSDSyncTests/Fixtures/auth_methods.json` (sanitized from the real captured response — same shape: modern `oauth2.providers[]`, dual `authURL`/`authUrl`, extra blocks):

```json
{
  "password": {"identityFields": ["email"], "enabled": true},
  "oauth2": {
    "providers": [
      {"name": "google", "displayName": "Google", "state": "STATE_G",
       "authURL": "https://accounts.google.com/o/oauth2/v2/auth?client_id=X&code_challenge=CH_G&code_challenge_method=S256&response_type=code&scope=email&state=STATE_G&redirect_uri=",
       "authUrl": "https://accounts.google.com/o/oauth2/v2/auth?client_id=X&state=STATE_G&redirect_uri=",
       "codeVerifier": "VERIFIER_G", "codeChallenge": "CH_G", "codeChallengeMethod": "S256"},
      {"name": "github", "displayName": "GitHub", "state": "STATE_H",
       "authURL": "https://github.com/login/oauth/authorize?client_id=Y&state=STATE_H&redirect_uri=",
       "authUrl": "https://github.com/login/oauth/authorize?client_id=Y",
       "codeVerifier": "VERIFIER_H", "codeChallenge": "CH_H", "codeChallengeMethod": "S256"}
    ],
    "enabled": true
  },
  "mfa": {"enabled": false, "duration": 0},
  "otp": {"enabled": false, "duration": 0},
  "authProviders": [], "usernamePassword": false, "emailPassword": true
}
```

- [ ] **Step 2: Write the failing test** `GSDKit/Tests/GSDSyncTests/AuthModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDSync

struct AuthModelsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesAuthMethodsModernShape() throws {
        let methods = try JSONDecoder().decode(AuthMethods.self, from: fixture("auth_methods"))
        #expect(methods.providers.count == 2)
        let google = try #require(methods.providers.first { $0.name == "google" })
        #expect(google.displayName == "Google")
        #expect(google.state == "STATE_G")
        #expect(google.codeVerifier == "VERIFIER_G")      // the value that MUST thread to authWithOAuth2
        #expect(google.codeChallengeMethod == "S256")
        #expect(google.authURL.hasSuffix("redirect_uri="))  // client appends the redirect here
        #expect(methods.providers[1].name == "github")
    }

    @Test func decodesAuthResult() throws {
        let json = Data(#"{"token":"jwt.token.here","record":{"id":"u1","email":"v@example.com","extra":"ignored"}}"#.utf8)
        let result = try JSONDecoder().decode(AuthResult.self, from: json)
        #expect(result.token == "jwt.token.here")
        #expect(result.record.email == "v@example.com")
    }
}
```

- [ ] **Step 3: Run to verify it fails.** `cd GSDKit && swift test --filter AuthModelsTests` → FAIL (`AuthMethods`/`AuthResult` undefined). *(If `Bundle.module` is nil, the `Fixtures` resource already exists from 5a's `.copy("Fixtures")` in `Package.swift` — new files under it are picked up; no Package change needed.)*

- [ ] **Step 4: Create `PocketBaseError`** `GSDKit/Sources/GSDSync/PocketBaseError.swift`:

```swift
import Foundation

/// Typed errors from the PocketBase client (§8). `public` — the App surfaces these.
public enum PocketBaseError: Error, Equatable {
    case network(String)                            // transport failure
    case http(status: Int, body: String)            // non-2xx, no PB error envelope
    case pocketBase(status: Int, message: String)   // decoded PB {message, ...}
    case decoding(String)                           // body didn't match the expected shape
}

/// PocketBase's standard error envelope (internal — only the client decodes it).
struct PBErrorEnvelope: Decodable { let message: String }
```

- [ ] **Step 5: Create `AuthModels`** `GSDKit/Sources/GSDSync/AuthModels.swift`:

```swift
import Foundation

/// `GET /api/collections/users/auth-methods` (modern PocketBase ≥0.23 shape — read `oauth2.providers[]`;
/// the deprecated top-level `authProviders` mirror is ignored). Internal — only the client/AuthService use it.
struct AuthMethods: Decodable, Equatable {
    var providers: [OAuthProvider]
    private enum CodingKeys: String, CodingKey { case oauth2 }
    private enum OAuth2Keys: String, CodingKey { case providers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let o = try c.nestedContainer(keyedBy: OAuth2Keys.self, forKey: .oauth2)
        providers = try o.decode([OAuthProvider].self, forKey: .providers)
    }
    init(providers: [OAuthProvider]) { self.providers = providers }
}

/// One provider entry. The `state`/`codeVerifier` are per-attempt PKCE values that MUST be threaded
/// back (verifier) and validated (state). Internal.
struct OAuthProvider: Decodable, Equatable {
    var name: String
    var displayName: String
    var state: String
    var authURL: String
    var codeVerifier: String
    var codeChallenge: String
    var codeChallengeMethod: String
}

/// `POST .../auth-with-oauth2` and `.../auth-refresh` result. `public` — the App reads the account.
public struct AuthResult: Decodable, Equatable, Sendable {
    public var token: String
    public var record: AuthRecord
}

/// The authenticated user (extra PB fields ignored). `public`.
public struct AuthRecord: Decodable, Equatable, Sendable {
    public var id: String
    public var email: String
}
```

- [ ] **Step 6: Run to verify it passes.** `cd GSDKit && swift test --filter AuthModelsTests` → PASS (2 tests).

- [ ] **Step 7: Commit.**
```bash
git add GSDKit/Sources/GSDSync/PocketBaseError.swift GSDKit/Sources/GSDSync/AuthModels.swift GSDKit/Tests/GSDSyncTests/AuthModelsTests.swift GSDKit/Tests/GSDSyncTests/Fixtures/auth_methods.json
git commit -m "feat(sync): add PocketBase auth models + typed errors (A49)"
```

---

### Task A2: `JWT` — `exp` decode + proactive-refresh check

**Files:**
- Create: `GSDKit/Sources/GSDSync/JWT.swift`
- Test: `GSDKit/Tests/GSDSyncTests/JWTTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/JWTTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDSync

struct JWTTests {
    /// Build a JWT with a given payload (header + payload base64url, dummy signature).
    private func makeJWT(_ payloadJSON: String) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        return "\(header).\(b64url(Data(payloadJSON.utf8))).sig"
    }

    @Test func decodesExp() {
        let token = makeJWT(#"{"exp":1893456000,"id":"u1"}"#)   // 2030-01-01
        #expect(JWT.expiry(token).map { Int($0.timeIntervalSince1970) } == 1893456000)
    }

    @Test func malformedTokenHasNoExpiry() {
        #expect(JWT.expiry("only.two") == nil)
        #expect(JWT.expiry("garbage") == nil)
    }

    @Test func expiresWithinSkew() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let soon = makeJWT(#"{"exp":1000000030}"#)               // 30s out
        let far  = makeJWT(#"{"exp":1893456000}"#)
        #expect(JWT.expiresWithin(60, of: soon, now: now) == true)   // within 60s skew
        #expect(JWT.expiresWithin(60, of: far, now: now) == false)
        #expect(JWT.expiresWithin(60, of: "garbage", now: now) == true)  // unparseable → refresh/reauth
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter JWTTests` → FAIL (`JWT` undefined).

- [ ] **Step 3: Create `JWT`** `GSDKit/Sources/GSDSync/JWT.swift`:

```swift
import Foundation

/// Decodes the `exp` claim from a PocketBase JWT and answers the proactive-refresh question. Pure;
/// does NOT verify the signature (the server does). Internal. PROBE-VERIFIED (17/17).
enum JWT {
    /// The `exp` (expiry) as a `Date`, or nil if the token is malformed or has no numeric `exp`.
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// True when `token` expires within `skew` of `now`, OR is unparseable (treat as needs-refresh).
    static func expiresWithin(_ skew: TimeInterval, of token: String, now: Date) -> Bool {
        guard let exp = expiry(token) else { return true }
        return exp.timeIntervalSince(now) <= skew
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter JWTTests` → PASS (3 tests).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/JWT.swift GSDKit/Tests/GSDSyncTests/JWTTests.swift
git commit -m "feat(sync): add JWT exp decode + proactive-refresh check (A53 support)"
```

---

### Task A3: `PocketBaseClient` (request-executor seam + auth endpoints + error mapping)

**Files:**
- Create: `GSDKit/Sources/GSDSync/PocketBaseClient.swift`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/auth_with_oauth2.json`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/pb_error.json`
- Test: `GSDKit/Tests/GSDSyncTests/PocketBaseClientTests.swift`

> `auth_with_oauth2.json` is **best-effort** (no interactive sign-in is possible in tests) — reconcile against a real exchange during the live round-trip (A56); specifically confirm whether `state` must be in the POST body.

- [ ] **Step 1: Create the fixtures.**

`GSDKit/Tests/GSDSyncTests/Fixtures/auth_with_oauth2.json`:
```json
{"token": "header.payload.signature", "record": {"id": "user_123", "email": "v@example.com", "verified": true, "collectionName": "users"}}
```

`GSDKit/Tests/GSDSyncTests/Fixtures/pb_error.json`:
```json
{"status": 400, "message": "Failed to authenticate.", "data": {}}
```

- [ ] **Step 2: Write the failing test** `GSDKit/Tests/GSDSyncTests/PocketBaseClientTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDSync

struct PocketBaseClientTests {
    /// Captures the last request and returns a scripted (data, status) keyed by URL path suffix.
    final class FakeExecutor: RequestExecuting, @unchecked Sendable {
        var routes: [String: (Data, Int)] = [:]   // path-suffix → (body, status)
        private(set) var lastRequest: URLRequest?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let path = request.url!.path
            let (data, status) = routes.first { path.hasSuffix($0.key) }?.value ?? (Data(), 404)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
    }
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func client(_ exec: FakeExecutor) -> PocketBaseClient {
        PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
    }

    @Test func authMethodsDecodesAndIsUnauthenticated() async throws {
        let exec = FakeExecutor(); exec.routes["auth-methods"] = (try fixture("auth_methods"), 200)
        let methods = try await client(exec).authMethods()
        #expect(methods.providers.contains { $0.name == "google" })
        #expect(exec.lastRequest?.httpMethod == "GET")
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)   // bootstrap = no auth
    }

    @Test func authWithOAuth2SendsPKCEBodyAndDecodes() async throws {
        let exec = FakeExecutor(); exec.routes["auth-with-oauth2"] = (try fixture("auth_with_oauth2"), 200)
        let result = try await client(exec).authWithOAuth2(
            provider: "google", code: "CODE", codeVerifier: "VERIFIER_G", redirectURL: "https://api.vinny.io/ios-oauth-redirect/")
        #expect(result.record.email == "v@example.com")
        // the request body carries the exact PKCE values (guards the threaded-verifier invariant)
        let body = try #require(exec.lastRequest?.httpBody)
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        #expect(sent["provider"] == "google")
        #expect(sent["code"] == "CODE")
        #expect(sent["codeVerifier"] == "VERIFIER_G")
        #expect(sent["redirectURL"] == "https://api.vinny.io/ios-oauth-redirect/")
    }

    @Test func errorStatusMapsToPocketBaseError() async throws {
        let exec = FakeExecutor(); exec.routes["auth-with-oauth2"] = (try fixture("pb_error"), 400)
        await #expect(throws: PocketBaseError.pocketBase(status: 400, message: "Failed to authenticate.")) {
            _ = try await client(exec).authWithOAuth2(provider: "google", code: "x", codeVerifier: "v", redirectURL: "r")
        }
    }

    @Test func authRefreshSetsAuthorizationHeader() async throws {
        let exec = FakeExecutor(); exec.routes["auth-refresh"] = (try fixture("auth_with_oauth2"), 200)
        _ = try await client(exec).authRefresh(token: "TOK")
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == "TOK")
    }
}
```

- [ ] **Step 3: Run to verify it fails.** `cd GSDKit && swift test --filter PocketBaseClientTests` → FAIL (`PocketBaseClient`/`RequestExecuting` undefined).

- [ ] **Step 4: Create `PocketBaseClient`** `GSDKit/Sources/GSDSync/PocketBaseClient.swift`:

```swift
import Foundation

/// Executes a `URLRequest` → (data, HTTP response). The seam that lets tests drive responses from
/// fixtures without a network. Internal.
protocol RequestExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live executor over `URLSession`. Internal.
struct URLSessionExecutor: RequestExecuting {
    let session: URLSession
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PocketBaseError.network("non-HTTP response") }
            return (data, http)
        } catch let e as PocketBaseError { throw e }
        catch { throw PocketBaseError.network(error.localizedDescription) }
    }
}

/// Minimal hand-built PocketBase REST client over `URLSession` (§7.0). Auth endpoints for 5b; the
/// generic `authedRequest` helper is consumed by 5c's CRUD. All requests go through `RequestExecuting`
/// so tests inject fixtures. `public` — the App constructs it. Token header is the raw JWT (PB strips
/// an optional "Bearer ").
public final class PocketBaseClient: Sendable {
    private let baseURL: String
    private let executor: RequestExecuting

    /// Production init (live `URLSession`).
    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.executor = URLSessionExecutor(session: session)
    }
    /// Test init — inject a fake executor. Internal.
    init(baseURL: String, executor: RequestExecuting) {
        self.baseURL = baseURL
        self.executor = executor
    }

    func authMethods() async throws -> AuthMethods {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-methods")!)
        req.httpMethod = "GET"   // unauthenticated bootstrap call
        return try await send(req, as: AuthMethods.self)
    }

    func authWithOAuth2(provider: String, code: String, codeVerifier: String, redirectURL: String) async throws -> AuthResult {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-with-oauth2")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ["provider": provider, "code": code, "codeVerifier": codeVerifier, "redirectURL": redirectURL])
        return try await send(req, as: AuthResult.self)
    }

    func authRefresh(token: String) async throws -> AuthResult {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-refresh")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        return try await send(req, as: AuthResult.self)
    }

    /// Authed request builder for 5c CRUD (raw token in Authorization). `public`.
    public func authedRequest(path: String, method: String, token: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await executor.execute(request)
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(PBErrorEnvelope.self, from: data) {
                throw PocketBaseError.pocketBase(status: http.statusCode, message: env.message)
            }
            throw PocketBaseError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PocketBaseError.decoding(String(describing: error)) }
    }
}
```

- [ ] **Step 5: Run to verify it passes.** `cd GSDKit && swift test --filter PocketBaseClientTests` → PASS (4 tests). Then `cd GSDKit && swift test --filter GSDSyncTests` (Group A whole) → all green.

- [ ] **Step 6: Commit.**
```bash
git add GSDKit/Sources/GSDSync/PocketBaseClient.swift GSDKit/Tests/GSDSyncTests/PocketBaseClientTests.swift GSDKit/Tests/GSDSyncTests/Fixtures/auth_with_oauth2.json GSDKit/Tests/GSDSyncTests/Fixtures/pb_error.json
git commit -m "feat(sync): add PocketBaseClient (auth endpoints + error mapping) (A49/A50)"
```

---

## Group B — `AuthService` PKCE orchestration (`GSDSync`, `swift test`)

> Pure orchestration over the seams + injected clock — stateless across calls (per-attempt PKCE values are LOCAL to `signIn`, never cached). Run: `cd GSDKit && swift test --filter AuthServiceTests`. Maps **A51/A52/A53**.

### Task B1: Seams + `AuthConfig` + `AuthService.signIn` (stateful PKCE)

**Files:**
- Create: `GSDKit/Sources/GSDSync/AuthSeams.swift`
- Create: `GSDKit/Sources/GSDSync/AuthService.swift`
- Test: `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift` (the `signIn` cases; the file is extended in B2):

```swift
import Testing
import Foundation
@testable import GSDSync

struct AuthServiceTests {
    // Fake web-auth presenter: returns a scripted callback URL, or throws a scripted error.
    final class FakePresenter: WebAuthPresenting, @unchecked Sendable {
        var result: Result<URL, Error>
        private(set) var presentedURL: URL?
        init(_ result: Result<URL, Error>) { self.result = result }
        func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
            presentedURL = authURL
            return try result.get()
        }
    }
    final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
        private(set) var token: String?
        init(_ t: String? = nil) { token = t }
        func load() -> String? { token }
        func save(_ t: String) { token = t }
        func clear() { token = nil }
    }
    // Fake executor (same shape as PocketBaseClientTests) routing by path suffix.
    final class FakeExecutor: RequestExecuting, @unchecked Sendable {
        var routes: [String: (Data, Int)] = [:]
        private(set) var lastBody: Data?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.url!.path.hasSuffix("auth-with-oauth2") { lastBody = request.httpBody }
            let (data, status) = routes.first { request.url!.path.hasSuffix($0.key) }?.value ?? (Data(), 404)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func makeService(presenter: WebAuthPresenting, store: TokenStore, exec: FakeExecutor) throws -> AuthService {
        exec.routes["auth-methods"] = (try fixture("auth_methods"), 200)
        exec.routes["auth-with-oauth2"] = (try fixture("auth_with_oauth2"), 200)
        return AuthService(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                           presenter: presenter, tokenStore: store, config: .live)
    }

    @Test func signInHappyPathThreadsVerifierAndStoresToken() async throws {
        // The fixture's google provider has state STATE_G + codeVerifier VERIFIER_G.
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=AUTH_CODE&state=STATE_G")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        let result = try await service.signIn(provider: "google")
        #expect(result.record.email == "v@example.com")
        #expect(store.token == "header.payload.signature")              // token persisted
        // the verifier sent to authWithOAuth2 is THIS fetch's (guards the no-cache invariant, A51)
        let sent = try JSONDecoder().decode([String: String].self, from: #require(exec.lastBody))
        #expect(sent["codeVerifier"] == "VERIFIER_G")
        #expect(sent["code"] == "AUTH_CODE")
        // and the presented authURL had the redirect appended
        #expect(presenter.presentedURL?.absoluteString.contains("redirect_uri=https%3A%2F%2Fapi.vinny.io%2Fios-oauth-redirect%2F") == true)
    }

    @Test func stateMismatchIsRejected() async throws {
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=AUTH_CODE&state=WRONG")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.stateMismatch) { _ = try await service.signIn(provider: "google") }
        #expect(store.token == nil)                                     // no token on CSRF failure
    }

    @Test func userCancelPropagatesAndStoresNothing() async throws {
        let presenter = FakePresenter(.failure(AuthError.cancelled))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.cancelled) { _ = try await service.signIn(provider: "google") }
        #expect(store.token == nil)
    }

    @Test func unknownProviderThrows() async throws {
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=x&state=y")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.providerNotFound("apple")) { _ = try await service.signIn(provider: "apple") }
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter AuthServiceTests` → FAIL (`AuthService`/`WebAuthPresenting`/`TokenStore`/`AuthConfig`/`AuthError` undefined).

- [ ] **Step 3: Create the seams + config** `GSDKit/Sources/GSDSync/AuthSeams.swift`:

```swift
import Foundation

/// Injected config for the auth flow (not hardcoded). `public`.
public struct AuthConfig: Sendable {
    public var baseURL: String
    public var redirectURI: String
    public var callbackScheme: String
    public init(baseURL: String, redirectURI: String, callbackScheme: String) {
        self.baseURL = baseURL; self.redirectURI = redirectURI; self.callbackScheme = callbackScheme
    }
    /// The owner's live backend + the configured bounce redirect (set up + tested).
    public static let live = AuthConfig(
        baseURL: "https://api.vinny.io",
        redirectURI: "https://api.vinny.io/ios-oauth-redirect/",
        callbackScheme: "gsd")
}

/// Presents an OAuth web-auth session and returns the final callback URL. App impl =
/// `ASWebAuthenticationSession`; tests use a fake. (Mirrors the Phase-4 `ReminderScheduling` seam.) `public`.
public protocol WebAuthPresenting: Sendable {
    func present(authURL: URL, callbackURLScheme: String) async throws -> URL
}

/// Persists the auth token. App impl = Keychain; tests = in-memory. `public`.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

public enum AuthError: Error, Equatable, Sendable {
    case cancelled                  // user dismissed the web sheet (silent)
    case presentationFailed         // the session couldn't start (surfaced)
    case stateMismatch              // returned state != sent state (CSRF)
    case missingCode                // callback had no code
    case providerNotFound(String)   // auth-methods didn't list the provider
    case notSignedIn                // refresh with no stored token
}
```

- [ ] **Step 4: Create `AuthService`** `GSDKit/Sources/GSDSync/AuthService.swift`:

```swift
import Foundation

/// Stateful-PKCE auth orchestration over the seams (§8). Stateless across calls — per-attempt
/// `{state, codeVerifier}` are LOCAL to `signIn`, never cached. `public`. PROBE-VERIFIED (17/17).
/// (Refresh/validToken land in B2.)
public struct AuthService: Sendable {
    private let client: PocketBaseClient
    private let presenter: WebAuthPresenting
    private let tokenStore: TokenStore
    private let config: AuthConfig

    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore, config: AuthConfig) {
        self.client = client; self.presenter = presenter; self.tokenStore = tokenStore; self.config = config
    }

    /// ONE auth-methods fetch; hold `{state, codeVerifier}` locally; present; validate state; exchange; store.
    public func signIn(provider: String) async throws -> AuthResult {
        let methods = try await client.authMethods()
        guard let p = methods.providers.first(where: { $0.name == provider }) else {
            throw AuthError.providerNotFound(provider)
        }
        let authURL = try buildAuthURL(p.authURL, redirectURI: config.redirectURI)
        let callback = try await presenter.present(authURL: authURL, callbackURLScheme: config.callbackScheme)
        let (code, state) = parseCallback(callback)
        guard state == p.state else { throw AuthError.stateMismatch }   // CSRF before anything else
        guard let code else { throw AuthError.missingCode }
        let result = try await client.authWithOAuth2(
            provider: provider, code: code, codeVerifier: p.codeVerifier, redirectURL: config.redirectURI)
        tokenStore.save(result.token)
        return result
    }

    public func signOut() { tokenStore.clear() }

    // MARK: helpers (internal — exercised via signIn; PROBE-VERIFIED)
    func buildAuthURL(_ base: String, redirectURI: String) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")               // encodeURIComponent-equivalent
        let enc = redirectURI.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirectURI
        guard let url = URL(string: base + enc) else { throw AuthError.presentationFailed }
        return url
    }
    func parseCallback(_ url: URL) -> (code: String?, state: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (items.first { $0.name == "code" }?.value, items.first { $0.name == "state" }?.value)
    }
}
```

- [ ] **Step 5: Run to verify it passes.** `cd GSDKit && swift test --filter AuthServiceTests` → PASS (4 `signIn` tests).

- [ ] **Step 6: Commit.**
```bash
git add GSDKit/Sources/GSDSync/AuthSeams.swift GSDKit/Sources/GSDSync/AuthService.swift GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift
git commit -m "feat(sync): add AuthService stateful-PKCE signIn over seams (A51/A52)"
```

---

### Task B2: `AuthService` token refresh + `validToken` (extend a valid JWT)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/AuthService.swift`
- Modify: `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift`

- [ ] **Step 1: Add the failing tests** — append these to `AuthServiceTests` (inside the struct, after the `signIn` tests):

```swift
    private func makeJWT(exp: Int) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let h = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        return "\(h).\(b64url(Data("{\"exp\":\(exp)}".utf8))).sig"
    }
    // refresh/validToken/signOut don't use the presenter; a dummy failing one is fine.
    private func refreshService(store: TokenStore, exec: FakeExecutor, now: Date) -> AuthService {
        AuthService(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                    presenter: FakePresenter(.failure(AuthError.cancelled)),
                    tokenStore: store, config: .live, now: { now })
    }

    @Test func validTokenReturnsFreshTokenWithoutRefreshing() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fresh = makeJWT(exp: 1_893_456_000)                       // far future
        let store = InMemoryTokenStore(fresh); let exec = FakeExecutor()  // NO auth-refresh route
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == fresh)                                       // as-is; refresh not called (would 404)
    }

    @Test func validTokenRefreshesWhenNearExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 1_000_000_030)); let exec = FakeExecutor()  // 30s → within 60s skew
        exec.routes["auth-refresh"] = (try fixture("auth_with_oauth2"), 200)
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == "header.payload.signature")                  // refreshed
        #expect(store.token == "header.payload.signature")            // persisted
    }

    @Test func validTokenNilWhenSignedOut() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let token = try await refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(), now: now).validToken()
        #expect(token == nil)
    }

    @Test func refreshFailureClearsTokenAndThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 1_000_000_030)); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("pb_error"), 401)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { _ = try await service.refresh() }
        #expect(store.token == nil)                                   // cleared → re-auth required
    }

    @Test func signOutClearsToken() {
        let store = InMemoryTokenStore("tok")
        refreshService(store: store, exec: FakeExecutor(), now: Date(timeIntervalSince1970: 0)).signOut()
        #expect(store.token == nil)
    }
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter AuthServiceTests` → FAIL (`validToken`/`refresh` undefined; the `now:` init param doesn't exist).

- [ ] **Step 3: Extend `AuthService`** in `GSDKit/Sources/GSDSync/AuthService.swift`. (a) Add two stored properties + extend the init (the new params are **defaulted**, so B1's call sites are unaffected):

```swift
    private let refreshSkew: TimeInterval
    private let now: @Sendable () -> Date

    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore,
                config: AuthConfig, refreshSkew: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.presenter = presenter; self.tokenStore = tokenStore
        self.config = config; self.refreshSkew = refreshSkew; self.now = now
    }
```

(Replace the existing 1-line init with the above; delete the old `public init(client:presenter:tokenStore:config:)`.)

(b) Add the two methods (after `signOut()`):

```swift
    /// A usable token, refreshing proactively near expiry; nil if signed out. Throws if refresh fails
    /// (caller prompts re-auth).
    public func validToken() async throws -> String? {
        guard let token = tokenStore.load() else { return nil }
        guard JWT.expiresWithin(refreshSkew, of: token, now: now()) else { return token }
        return try await refresh().token
    }

    /// Extend a still-valid JWT (no refresh-token). On failure, clear + signal re-auth.
    @discardableResult
    public func refresh() async throws -> AuthResult {
        guard let token = tokenStore.load() else { throw AuthError.notSignedIn }
        do {
            let result = try await client.authRefresh(token: token)
            tokenStore.save(result.token)
            return result
        } catch {
            tokenStore.clear()   // expired/invalid → require re-auth
            throw error
        }
    }
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter AuthServiceTests` → PASS (9 tests total).

- [ ] **Step 5: Run the whole `GSDSync` suite.** `cd GSDKit && swift test --filter GSDSyncTests` → all green (Group A + B). Then `cd GSDKit && swift test` (full suite) → no regression.

- [ ] **Step 6: Commit.**
```bash
git add GSDKit/Sources/GSDSync/AuthService.swift GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift
git commit -m "feat(sync): add AuthService token refresh + validToken (A53)"
```

---

## Group C — Live edge + Account UI (App, build + MANUAL)

> The runtime frameworks (`ASWebAuthenticationSession`, Keychain, SwiftUI) — **NOT unit-tested**; verified by `xcodebuild` + simctl render, and ultimately by the live round-trip (A56). The App now consumes `GSDSync`, so this group adds the app→`GSDSync` `project.yml` dependency. Maps **A54/A55**.

### Task C1: `LiveWebAuthPresenter` + `KeychainTokenStore` + app→GSDSync dependency

**Files:**
- Create: `App/Auth/LiveWebAuthPresenter.swift`
- Create: `App/Auth/KeychainTokenStore.swift`
- Modify: `project.yml` (add `GSDSync` to the `GSD` target's dependencies)

- [ ] **Step 1: Add the `GSDSync` dependency to the `GSD` target in `project.yml`.** Under `targets: GSD: dependencies:`, after the `GSDStore` entry, add:

```yaml
      - package: GSDKit
        product: GSDSync
```

Then regenerate: `xcodegen generate`.

- [ ] **Step 2: Create `LiveWebAuthPresenter`** `App/Auth/LiveWebAuthPresenter.swift`:

```swift
import AuthenticationServices
import UIKit
import GSDSync

/// Live `WebAuthPresenting` over `ASWebAuthenticationSession` (§8.2). Build + MANUAL — exercised by the
/// live round-trip (A56), never `swift test`. Distinguishes user-cancel (silent) from a presentation
/// failure (surfaced). The session is created/started on the main actor and retained until completion.
final class LiveWebAuthPresenter: NSObject, WebAuthPresenting, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackURLScheme) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                        continuation.resume(throwing: AuthError.cancelled)          // user dismissed → silent
                    } else {
                        continuation.resume(throwing: AuthError.presentationFailed) // anything else → surfaced
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false   // reuse an existing Google session
                self.session = session
                if !session.start() {
                    continuation.resume(throwing: AuthError.presentationFailed)     // couldn't even start
                }
            }
        }
    }
}

extension LiveWebAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window ?? ASPresentationAnchor()
    }
}
```

> **Build note (runtime-only code):** this compiles under Swift 6 strict concurrency as written; if the toolchain flags the `presentationContextProvider`/anchor isolation, satisfy it with the minimal annotation the compiler asks for (e.g. `MainActor.assumeIsolated`) — it's a wiring detail on un-unit-tested code, not a logic change. The cancel-vs-failure branching is the part that matters.

- [ ] **Step 3: Create `KeychainTokenStore`** `App/Auth/KeychainTokenStore.swift`:

```swift
import Foundation
import Security
import GSDSync

/// `TokenStore` over the Keychain (§8.3). A PLAIN generic-password item — **NO access group** (the
/// shared group needs a team/app-ID-prefix entitlement + an extension, both Phase 6). Build + MANUAL
/// (persistence across launches is verified in the live round-trip). No mutable state → `Sendable`.
struct KeychainTokenStore: TokenStore {
    private let service = "dev.vinny.gsd.auth"
    private let account = "pocketbase-token"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent upsert: delete then add
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
```

- [ ] **Step 4: Build to verify.** `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build-app build` → **BUILD SUCCEEDED** (the App now links `GSDSync` and both live impls conform to the seams).

- [ ] **Step 5: Commit.**
```bash
git add App/Auth/LiveWebAuthPresenter.swift App/Auth/KeychainTokenStore.swift project.yml GSD.xcodeproj/project.pbxproj
git commit -m "feat(auth): add live ASWebAuthenticationSession presenter + Keychain token store (A54)"
```

---

### Task C2: `SessionStore` + Account section + `GSDApp` wiring

> **Correction to the spec's §3:** **no `CFBundleURLTypes` / `Info.plist` URL-scheme registration is needed.** `ASWebAuthenticationSession` intercepts its `callbackURLScheme` internally; Info.plist registration is only for `openURL`-based callbacks. So C2 touches **no** `project.yml`/`Info.plist` (the app→`GSDSync` dep was added in C1).

**Files:**
- Create: `App/Auth/SessionStore.swift`
- Modify: `App/Settings/SettingsView.swift` (add an Account section + the `SessionStore` environment)
- Modify: `App/GSDApp.swift` (construct + inject the auth stack)

- [ ] **Step 1: Create `SessionStore`** `App/Auth/SessionStore.swift`:

```swift
import Foundation
import Observation
import GSDSync

/// App-facing auth state (§8). Wraps `AuthService` for SwiftUI: signed-in/account/in-progress/error.
/// Keeps auth UI-state OUT of the pure `AuthService` (the `TaskStore` `@MainActor @Observable` precedent).
/// The email is cached in `UserDefaults` for an instant, offline launch restore; the token lives in
/// the Keychain. Build + MANUAL (the wrapped `AuthService` logic is unit-tested in Group B).
@MainActor
@Observable
final class SessionStore {
    private(set) var email: String?
    private(set) var inProgress = false
    private(set) var lastError: String?

    private let auth: AuthService
    private let tokenStore: TokenStore
    private let emailKey = "gsd.accountEmail"

    init(auth: AuthService, tokenStore: TokenStore) {
        self.auth = auth
        self.tokenStore = tokenStore
        if tokenStore.load() != nil {                                  // restore at launch (no network)
            email = UserDefaults.standard.string(forKey: emailKey)
        }
    }

    var isSignedIn: Bool { email != nil || tokenStore.load() != nil }

    func signIn(provider: String) async {
        inProgress = true; lastError = nil
        defer { inProgress = false }
        do {
            let result = try await auth.signIn(provider: provider)
            email = result.record.email
            UserDefaults.standard.set(result.record.email, forKey: emailKey)
        } catch AuthError.cancelled {
            // user dismissed — silent, stay signed out, no banner
        } catch {
            lastError = String(localized: "Sign-in failed. Please try again.")
        }
    }

    func signOut() {
        auth.signOut()
        email = nil
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
```

- [ ] **Step 2: Add the Account section to `SettingsView`.** (a) Add the environment property next to the existing `@Environment(TaskStore.self)`:

```swift
    @Environment(SessionStore.self) private var session
```

(b) Add `accountSection` to the `Form` (place it right after `appearanceSection`):

```swift
            Form {
                appearanceSection
                accountSection
                archiveSection
                notificationSection
                DataStorageView()
                aboutSection
            }
```

(c) Add the section itself (alongside the other `private var …Section` computed properties):

```swift
    private var accountSection: some View {
        Section(String(localized: "Account")) {
            if session.isSignedIn {
                LabeledContent(String(localized: "Signed in"),
                               value: session.email ?? String(localized: "Account"))
                Button(role: .destructive) {
                    session.signOut()
                } label: {
                    Label(String(localized: "Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
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
            }
            if let error = session.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
```

> Note: the About section still reads "Nothing is sent to a server." That copy updates when sync actually ships (5c/5d); 5b stays on-branch, so the transient contradiction never reaches users.

- [ ] **Step 3: Wire the auth stack in `GSDApp`.** (a) Add `import GSDSync` at the top. (b) Add the `session` state + construct it in `init()` (after the `store` setup, before `BackgroundRefresh.register`):

```swift
    @State private var session: SessionStore
```
```swift
        // Auth + transport (Phase 5b). Live seams; the pure AuthService logic is unit-tested.
        let tokenStore = KeychainTokenStore()
        let authService = AuthService(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            presenter: LiveWebAuthPresenter(),
            tokenStore: tokenStore,
            config: .live)
        _session = State(initialValue: SessionStore(auth: authService, tokenStore: tokenStore))
```

(c) Inject it into the environment (next to `.environment(store)`):

```swift
                ContentView()
                    .environment(store)
                    .environment(session)
```

- [ ] **Step 4: Regenerate + build + render-smoke.**
```bash
xcodegen generate    # picks up the new App/Auth/*.swift files
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build-app build
```
Expected: **BUILD SUCCEEDED**. Then install + launch + screenshot Settings on the iPhone 17 sim and confirm the **Account** section renders with "Sign in with Google" (the section is reachable; tapping it is the live round-trip below).

- [ ] **Step 5: Commit.**
```bash
git add App/Auth/SessionStore.swift App/Settings/SettingsView.swift App/GSDApp.swift GSD.xcodeproj/project.pbxproj
git commit -m "feat(auth): add SessionStore + Settings Account section + app wiring (A55)"
```

---

## Live verification gate (A56 — MANUAL, gates merge)

> Built code stays on `phase-5b-auth-transport`; **do NOT merge to `main`** until this passes. The redirect path (authorized URI + bounce page → `gsd://oauth-callback`) is already set up + tested by the owner.

- [ ] **L1 — Real Google round-trip.** On a sim/device, open Settings → Account → **Sign in with Google** → complete Google auth in the sheet → confirm it returns, the section shows the signed-in email, and no error. (Exercises `LiveWebAuthPresenter` → bounce → `authWithOAuth2` → token → Keychain.)
- [ ] **L2 — Capture + reconcile the real exchange.** During L1, capture the real `auth-with-oauth2` response (Charles/proxy, or PocketBase logs) and **reconcile `auth_with_oauth2.json`** to the true shape; **confirm whether `state` is required in the POST body** (spec §8 watch-out) and adjust `PocketBaseClient.authWithOAuth2` + the test if so. Re-run `swift test --filter GSDSyncTests`.
- [ ] **L3 — Keychain persistence.** Force-quit + relaunch; confirm Settings still shows signed-in (the launch restore reads the Keychain token + cached email).
- [ ] **L4 — §8.4(c) email convergence.** Confirm the signed-in PocketBase user is the **same** account/email used on the web app (so synced data will match in 5c). If Google returns the same verified email and PocketBase links by email → one user. Record the result.
- [ ] **L5 — Refresh (optional/observational).** If feasible, confirm a near-expiry token refreshes silently (or note PB's token TTL for 5c's cadence).

## Definition of Done (Phase 5b)

- [ ] **`swift test` green:** Group A (AuthModels, JWT, PocketBaseClient) + Group B (AuthService signIn/refresh/validToken) all pass; full suite shows no regression.
- [ ] **Acceptance A49–A55** map to passing unit tests + a clean App build + the Account section rendering (simctl).
- [ ] **A56 (the live gate) passes:** L1–L4 confirmed by the owner. **This is the merge gate** — 5b is NOT merged on unit-green alone.
- [ ] **Scope fences held:** `GSDSync` Foundation-only + `GSDModel`-only (no `GSDStore`); frameworks confined to the App behind the seams; plain Keychain (no access group); no task CRUD/SSE.
- [ ] **5c carry-forward noted:** the `decodeList` `{items:[…]}` pagination unwrap; the authed-request helper feeds CRUD; the real `auth-with-oauth2` shape from L2.

## Out of scope (explicit — deferred)

Task CRUD / pull / push / queue-drain / sync-history → 5c. SSE realtime / safety-net / health → 5c/5d. GitHub + Apple providers → later config (provider-agnostic code). Shared Keychain access group → Phase 6 (extensions).
