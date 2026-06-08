# Sign in with Apple — Apple Portal + PocketBase Setup (Option A)

**Date:** 2026-06-06
**Scope:** Backend/portal setup only. The iOS client rework is tracked separately (see [§5](#5-after-this-the-ios-rework-separate-work)).

---

## Context — why this approach (Option A)

We're adding **Sign in with Apple to both the iOS app and the web app (NextJS)**. The web app already authenticates via **PocketBase → Google** using the standard web OAuth flow (`authWithOAuth2`).

Apple binds each authorization code to the `client_id` that **started** the flow:

- **Native iOS sheet** → `client_id` = the **bundle ID** (`dev.vinny.gsd`)
- **Web** → `client_id` = a **Services ID**

A single stock PocketBase `apple` provider holds **one** `client_id`, so it cannot validate both audiences (see [pocketbase#6151](https://github.com/pocketbase/pocketbase/issues/6151)).

**Decision (Option A): unify both platforms on the PocketBase web OAuth flow.**

- PocketBase `apple` provider `client_id` = a **Services ID** (not the bundle ID).
- iOS **drops the native `SignInWithAppleButton`/`ASAuthorizationController` sheet** and routes Apple through the existing web-redirect path it already uses for Google (via the `https://api.vinny.io/ios-oauth-redirect/` bounce → `gsd://`).
- **Why:** one provider, and PocketBase's built-in `apple` slot auto-generates Apple's rotating client-secret JWT (the alternative — keep native + a 2nd OIDC slot — would mean self-rotating that secret every ≤6 months).
- **Cost:** iOS loses the native sheet. **No user-facing regression** — native Apple sign-in never worked at runtime (the backend was never configured), so the rework ships before Apple goes live on iOS.

---

## Reference values

| Thing | Value |
|---|---|
| Bundle ID (App ID) | `dev.vinny.gsd` |
| Team ID | `52HVJ3VDSM` |
| PocketBase base URL | `https://api.vinny.io` |
| **Services ID to create** | `dev.vinny.gsd.signin` *(your choice — must differ from the bundle ID)* |
| Web Return URL (PocketBase) | `https://api.vinny.io/api/oauth2-redirect` *(confirm against your Google client)* |
| iOS bounce Return URL | `https://api.vinny.io/ios-oauth-redirect/` |

> ⚠️ Do the steps **in order**: Apple portal → PocketBase → verify on web → (later) iOS rework. The moment PocketBase's `apple` `client_id` becomes the Services ID, the current native iOS build can no longer validate — which is fine, because it never worked at runtime, but it means the iOS rework lands before Apple ships on iOS.

---

## 1. Apple Developer Portal

### 1.0 Confirm prerequisites (from the earlier native setup)

- [ ] App ID **`dev.vinny.gsd`** has the *Sign in with Apple* capability enabled
- [ ] A *Sign in with Apple* **Key (.p8)** exists, and you have its **Key ID**
- [ ] You know your **Team ID** (`52HVJ3VDSM`)

> The same `.p8` key works for the Services ID below — keys attach to the primary App ID and cover its Services IDs. Do **not** create a new key.

### 1.1 Create the Services ID (the web client)

- [ ] developer.apple.com → **Certificates, Identifiers & Profiles → Identifiers**
- [ ] Change the top-right filter dropdown from **App IDs** to **Services IDs**
- [ ] Click **＋** → select **Services IDs** → **Continue**
- [ ] **Description:** `GSD Web Sign In`
- [ ] **Identifier:** `dev.vinny.gsd.signin` — reverse-DNS, **different from the bundle ID**
- [ ] **Continue → Register**

> ⚠️ The Identifier you choose here becomes the PocketBase **Client ID** in [§2](#2-pocketbase). Write it down exactly.

### 1.2 Configure Sign in with Apple on the Services ID

- [ ] Click the new `dev.vinny.gsd.signin` row
- [ ] Tick **Sign in with Apple** → click **Configure**
- [ ] **Primary App ID:** `dev.vinny.gsd`
- [ ] **Domains and Subdomains:** `api.vinny.io`
- [ ] **Return URLs** — add **both**:
  - [ ] `https://api.vinny.io/api/oauth2-redirect` (web / PocketBase)
  - [ ] `https://api.vinny.io/ios-oauth-redirect/` (iOS bounce, for the later rework)
- [ ] **Next → Done → Continue → Save**

> ⚠️ **Match the web Return URL to your Google setup.** Open your Google OAuth client in Google Cloud Console and copy its *Authorized redirect URI* — PocketBase uses the **same** `…/api/oauth2-redirect` path for every provider. Match it byte-for-byte, including the trailing slash (or lack of one).

### 1.3 Verify the domain

When you add the domain, Apple shows a **Download** button for `apple-developer-domain-association.txt` and a **Verify** step. Apple won't activate the domain until it can fetch that file.

- [ ] Host the file at exactly: `https://api.vinny.io/.well-known/apple-developer-domain-association.txt`
  - For PocketBase, drop it in **`pb_public/.well-known/`** (PocketBase serves `pb_public/` at the web root), or serve it via whatever reverse proxy (nginx/Caddy) fronts PocketBase.
- [ ] Confirm it loads in a browser
- [ ] Click **Verify** in Apple's sheet

---

## 2. PocketBase

### 2.1 Open the Apple provider

- **Newer PocketBase (v0.23+):** Collections → **users** → ⚙️ collection options → **OAuth2** tab → enable OAuth2 → **＋ Add provider → Apple**
- **Older PocketBase (<0.23):** **Settings → Auth providers → Apple**

*(Google is already configured here — Apple sits next to it.)*

### 2.2 Fill the fields

| Field | Value |
|---|---|
| **Client ID** | `dev.vinny.gsd.signin` ← the **Services ID** (⚠️ *not* the bundle ID) |
| **Team ID** | `52HVJ3VDSM` |
| **Key ID** | your `.p8`'s Key ID |
| **Private key** | the **entire** `.p8` contents, including the `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines |
| Duration (if shown) | leave default |

- [ ] Saved. *(PocketBase signs Apple's client-secret JWT for you from these — nothing to rotate.)*

### 2.3 Confirm account linking (convergence)

The design is **email-keyed convergence**: signing in with Apple using the same email as Google lands the **same** user. PocketBase does this automatically — on OAuth2 login it links to an existing user when the verified email matches, else creates one. The **users** collection already allows OAuth2 (Google works), so there's nothing per-provider to toggle.

- [ ] (Awareness only) Convergence is expected behavior, not a setting.

---

## 3. Verify on the web (before any iOS work)

Test the web path in isolation — it's independent of the iOS rework.

```js
await pb.collection('users').authWithOAuth2({ provider: 'apple' })
```

**Success looks like:**

- [ ] Apple popup → consent → popup closes → `pb.authStore` is populated
- [ ] Signing in with your **Google email** lands the **same** `users` record (verify the row)
- [ ] **Hide My Email** creates a **separate** `@privaterelay.appleid.com` record

---

## 4. Troubleshooting

| Error | Almost always means |
|---|---|
| `invalid_client` | PocketBase **Client ID ≠ the Services ID**, or Team ID / Key ID / `.p8` mismatch |
| `invalid_redirect_uri` / redirect mismatch | The Return URL in [§1.2](#12-configure-sign-in-with-apple-on-the-services-id) doesn't byte-match what PocketBase sent (path or trailing slash). **Fix it on the Services ID, not in PocketBase.** |
| Domain "could not be verified" | The `.well-known` file isn't reachable at `https://api.vinny.io/.well-known/apple-developer-domain-association.txt` |
| A 2nd account appears for your own email | Email didn't match/verify for linking — confirm the existing Google user's email is verified in PocketBase |

> **Most common failure = Return URL mismatch, and it's counterintuitive:** you fix it on **Apple's Services ID**, never in PocketBase. PocketBase always sends `…/api/oauth2-redirect`; Apple just checks that value against the Services ID's allow-list. "Invalid redirect" means *Apple's list* is missing that exact string — copy what Google uses and it'll match.

---

## 5. The iOS rework — ✅ DONE in the working tree (2026-06-07, uncommitted)

The backend is provider-agnostic, so the iOS client change was implemented ahead of §1–§3 (it can't be *live-tested* until the backend is configured, but it builds and the unit suite is green — iPhone 17 Pro + iPad Pro 13 M5, 452 GSDKit tests):

- ✅ Replaced the native `SignInWithAppleButton` (`App/Settings/SettingsView.swift`) with an **Apple-HIG-styled** button calling `session.signIn(provider: "apple")` — the same web-redirect path Google uses. **GitHub was wired in the same pass** (`signIn(provider: "github")`), since the backend already had the provider.
- ✅ Folded relay detection (`usingRelayEmail` / `AppleIdentity.isRelayEmail`) into `signIn(provider:)` so the "Hide My Email" note still fires (false for non-Apple providers).
- ✅ Retired the dead native bits: `AuthService.signInWithApple`, `SessionStore.signInWithApple`, their 3 tests, and the `com.apple.developer.applesignin` entitlement. **Kept** `AppleIdentity` (+ its 5 tests).
- **App Store note:** `SignInWithAppleButton` can't drive a web flow (it always triggers the native sheet), so the replacement is hand-rendered to follow Apple's button guidelines (black/white, Apple glyph, "Sign in with Apple" wording, corner radius).

### ⚠️ Add to the §1–§2 backend work: the `form_post` bounce gotcha (most likely live-gate failure)

Apple uses **`response_mode=form_post`** whenever the auth request includes the `email` scope — and we need `email` for the email-keyed convergence in §2.3. So Apple **POSTs** `code`/`state` to `https://api.vinny.io/ios-oauth-redirect/`, where Google **GETs** with a query string.

- [ ] Confirm the iOS bounce page accepts a **POST**, reads `code`/`state` from the **form body** (not just the query string), and 302-redirects to `gsd://…?code=…&state=…`.
- [ ] Same check for the web Return URL `…/api/oauth2-redirect` if PocketBase doesn't already handle Apple's form_post (it generally does for the built-in `apple` provider — verify).

If the bounce is GET-only (all Google ever needed), Apple dies at the bounce and the iOS app shows its generic "Sign-in failed" banner — a failure invisible to `swift test` and the build. **GitHub uses a plain GET redirect (no form_post), so `signIn(provider: "github")` is the one provider verifiable on a device today.**
