# App Store readiness — 2026-10-17

**Verdict: remaining distribution and owner checks still apply.** October 18 signed Catalyst follow-up: development-signed Debug and Release builds now pass, and the Release app opens the task matrix and reopens successfully. The previous normal-Mac-startup verification gap is closed. See the signed Mac evidence below; distribution validation, extension-host sharing, and the remaining physical-device/live-account checks are separate gates.

## October 18 follow-up

The owner authorized the remaining local work and is handling the certificate/profile mismatch. No signing assets, capabilities, App Store privacy answers, or privacy manifests were changed. Nothing was committed, pushed, deployed, or submitted.

### iPad menu verification closed

Allowed the complete Release lifecycle test to finish against the original context-menu implementation: **PASS**, approximately 298 seconds, `/tmp/gsd-followup-ipad-original.xcresult`. Capture, relaunch, edit/cancel, save, Complete, Show Completed, Delete, and Undo all succeeded. The previous three-minute interruptions were premature. XCTest spent repeated 60-second waits for animation-idle notifications while the menu was open; that runner delay is not evidence of a user-visible app hang.

A two-second process sample showed the app's main thread waiting in the run loop for 800 of 803 samples; a runner sample showed XCTest waiting for quiescence. Samples are retained in `build/release-readiness/followup-diagnostics/`. This is bounded diagnostic evidence, not a physical-device performance benchmark. A static-preview experiment also passed but did not remove the waits; it was discarded. `QuadrantCell.swift` has no retained change.

### Large-text editor fixed

Largest accessibility text revealed a real visual issue missed by the initial label/touch audits: the medium-height editor's expansion prompt covered the form. A new UI regression test failed before the fix (`/tmp/gsd-followup-large-red.xcresult`). Compact presenters now offer the large detent only at accessibility sizes and hide the redundant expansion prompt. The quadrant picker uses one column at accessibility sizes so labels do not break into narrow fragments. Standard-size two-column pickers and medium/large presentation remain unchanged.

The fixed regression and label/touch-target checks passed on iPhone 18 Pro / iOS 27.0 at the largest accessibility text size: `/tmp/gsd-followup-large-final.xcresult`. The regression also scrolls to Schedule, selects it, and confirms selection, then cancels the draft. Before/after screenshots were visually inspected. Additive UI checks live in `ReleaseReadinessTests` and remain opt-in.

### Decorative heading labels fixed

The iOS 26.5 sufficient-description audit reproduced a “Label not human-readable” finding for the decorative Delegate/person symbol in the matrix heading (`/tmp/gsd-followup-ios26-final.xcresult`). Hide only the redundant header images from accessibility in `QuadrantSection` and `QuadrantCell`; the adjacent quadrant names remain spoken and visible. The same test is retained as the regression; the focused rerun passed (`/tmp/gsd-followup-symbol-green.xcresult`). No audit findings are filtered or suppressed.

### Privacy policy prepared locally

Updated `/Users/vinnycarpenter/Projects/GSD/gsdtaskmanager.com/app/privacy/page.tsx` with an optional shared-link-title section and consistent introductory/device/third-party copy. It explains that the Apple-app setting is off by default, works independently of sync, requests the shared URL, may follow redirects, and exposes the URL/IP/normal request information to the requested site. It does not promise that URLs contain no personal information. The rest of the task database and GSD account token are not attached to this request.

The marketing site's static build passed (`/tmp/gsd-followup-policy-build.log`). Edited-file lint passed (`/tmp/gsd-followup-policy-targeted-lint.log`), and the rendered new section and every internal section link were checked. Full-site lint encounters three existing `no-require-imports` errors in the unrelated, untracked `GSD-ProductHunt-Gallery-1270x760/source/render.cjs`; those files and the existing `bun.lock` work were preserved. The web-guidance search required no new web API or layout pattern; the policy retains the existing semantic section/link structure.

**The live website remains unchanged until this local correction is published.** App Store Connect answers still need owner confirmation. Read-only inspection of the backend source confirms a 180-day feedback deletion job and the iOS client/tests cover a payload without an Authorization header. An unauthenticated request to the live control endpoint returned 404, so deployed controls/retention were not verified; no privileged credentials were used and no feedback was sent.

### Follow-up validation

- Swift package: **283 tests passed**, `/tmp/gsd-followup-tests.log`.
- Final unsigned iOS device archive: **PASS**, `/tmp/gsd-followup-ios-ready.xcarchive` and `/tmp/gsd-followup-ios-ready-archive.log`.
- Final unsigned Catalyst archive: **PASS**, `/tmp/gsd-followup-mac-ready.xcarchive` and `/tmp/gsd-followup-mac-ready-archive.log`.
- Automated sufficient-description and touch-target audits passed on the iPhone matrix/editor at standard and largest text sizes. This does not certify VoiceOver order, contrast, or all screens.
- Final-source iPad Pro 13-inch / iOS 27.0 label/touch-target audit passed at the largest accessibility text size: `/tmp/gsd-followup-ipad-large.xcresult`.
- Normal-size iPhone 17 Pro / iOS 26.5 lifecycle passed: `/tmp/gsd-followup-ios26-final.xcresult`. Its first matrix accessibility audit failed on the decorative icon described above; this result bundle is deliberately not reported as an all-green run. A focused rerun passed after the icon fix (`/tmp/gsd-followup-symbol-green.xcresult`).
- Final-source iPhone 18 Pro / iOS 27.0 large-text regression plus description/touch-target audits: **PASS**, `/tmp/gsd-followup-iphone-ready.xcresult` (2 tests).
- Final-source iPad Pro 13-inch / iOS 27.0 description/touch-target audits at the largest accessibility size: **PASS**, `/tmp/gsd-followup-ipad-ready.xcresult` (1 test). Screenshots are exported under `build/release-readiness/followup-iphone-ready/` and `followup-ipad-ready/`.
- Physical-device discovery reports the owner's iPhone as unavailable; connected QA targets are simulated. Hardware-only checks could not be performed.

For the largest-text regression, set the disposable simulator with `xcrun simctl ui <QA UUID> content_size accessibility-extra-extra-extra-large`, then run `ReleaseReadinessTests/testLargeTypeEditorHasRoomForContent` with `TEST_RUNNER_RELEASE_QA=1 TEST_RUNNER_LARGE_TYPE_QA=1`. Restore `content_size large` afterward. Do not impose a three-minute timeout on the iPad lifecycle test; its two long-press menus can each trigger multiple XCTest idle waits.

## Initial review: scope and environment

Reviewed the current checkout in `/Users/vinnycarpenter/Projects/GSD/gsd-iosapp`, initially clean. No commits, pushes, uploads, submissions, credential changes, capability changes, or privacy-declaration changes were made. The working directory supplied in the chat omitted the `GSD` parent directory.

Read AGENTS.md, CLAUDE.md, README, PRODUCT, coding standards, relevant product-spec sections, project configuration, package manifest, and current task notes. The instructions reference `openwiki/quickstart.md`, but that file is absent. Applied the iOS debugger and macOS build/run and packaging skills; loaded required ui-craft guidance, which defers native app design to Apple conventions. XcodeBuildMCP was unavailable; used Xcode, Simulator, XCUITest, and macOS accessibility instead.

Environment: macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), iOS Simulator/device SDK 27.1, Mac Catalyst SDK from macOS 27.0. Disposable QA simulators were created, preserving existing simulator installations.

Implementation is a SwiftUI iPhone/iPad app with **Mac Catalyst**, not a separate AppKit app. GSDModel, GSDStore, GSDWire, GSDSync, and GSDSnapshot share domain, GRDB persistence, network/auth, and extension contracts. GRDB is locked to 7.10.0. Widgets are iOS-only; the share extension supports Catalyst. `project.yml` remains the generated project's authority and was unchanged.

## Changes and user impact

1. **Backup restore validation and feedback.** Active tasks were validated, but archived/trashed tasks bypassed the same limits; malformed companion rows were dropped without increasing the skipped count. Validate all three task stores and include all dropped rows in feedback. Preserve absent versus explicitly empty companion stores. Two regression tests failed before the fix and passed afterward. Existing valid backup formats and field limits are unchanged.
2. **Mac View menu.** The running app exposed two View menus. Append navigation/sync commands to the system View menu with `CommandGroup(after: .sidebar)`. Runtime accessibility inspection after rebuilding confirmed one View menu containing Show Sidebar, Find, Today's Focus, all four quadrants, Dashboard, Archive, Settings, Sync Now, and Enter Full Screen.
3. **About accessibility.** Give the icon-only dismissal button the explicit label “Close About GSD.” Compiled successfully; VoiceOver speech remains a manual check.
4. **Stop finished celebration work.** The confetti Canvas stopped drawing after 1.6 seconds, but `startDate` never reset, so the animation timeline stayed unpaused. A cancellable view task now clears the particles and resets the timeline after the burst; enabling Reduce Motion also stops an active burst. This fixes a code-confirmed lifetime issue. No CPU or battery delta was measured, and this is not established as the cause of the separate iPad automation stall.
5. **Repeatable local lifecycle test.** Add an opt-in XCUITest for capture, relaunch persistence, cancelling a draft, saving an edit, completion visibility, deletion, and Undo. It does not seed or erase the store. Run only on a disposable QA simulator with `TEST_RUNNER_RELEASE_QA=1`. The existing seeded screenshot walk does replace its test data and was used only on a disposable simulator.

## Evidence ledger

### Build and automated tests

| Check | Result | Evidence |
|---|---|---|
| Initial Swift package suite | PASS: 281 tests, 31 suites | `/tmp/gsd-release-tests.log` |
| New tests before fix | FAIL as expected: 2 tests, 4 assertions | `/tmp/gsd-import-red.log` |
| Importer tests after fix | PASS: 13 tests | `/tmp/gsd-import-green.log` |
| Full suite after fix | PASS: 283 tests, 31 suites | `/tmp/gsd-readiness-final-tests.log` |
| Universal iOS Simulator Release build | PASS | `/tmp/gsd-readiness-ios.log` |
| Universal Catalyst Release build after menu fix | PASS, unsigned | `/tmp/gsd-readiness-mac-polish.log` |
| Device Release archive | PASS, unsigned | `/tmp/gsd-readiness-ios-final.xcarchive`, `/tmp/gsd-readiness-ios-final-archive.log` |
| Catalyst Release archive after fixes | PASS, unsigned | `/tmp/gsd-readiness-mac-final.xcarchive`, `/tmp/gsd-readiness-mac-final-archive.log` |
| Signed Catalyst Release build | BLOCKED: both installed provisioning profiles exclude the selected development certificate | `/tmp/gsd-readiness-mac-signed.log` |

The initial aborted iPad run is in `/tmp/gsd-readiness-ipad-lifecycle.log`; the final interrupted attempt is in `/tmp/gsd-readiness-ipad-final.log`. Neither is counted as passed.

The full suite includes migration, corruption-recovery, write ordering, backups, auth seams, sync, parser, notification math, and extension-contract tests. These are automated logic checks, not proof that live provider login, the production backend, or OS delivery works.

Archive inspection confirmed app/share/widget identifiers `dev.vinny.gsd`, `.share`, `.widgets`; all are version **3.0.0 (34)**. iOS minimum is 26.0 with iPhone/iPad device families and configured phone/tablet orientations. Catalyst archive minimum is macOS 26.0. iOS embeds both extensions; Catalyst embeds the share extension. App, extensions, and GRDB resource bundle contain privacy manifests. Presence and plist validity do not establish declaration accuracy or App Store validation.

The share-extension metadata extractor warns that it has no AppIntents framework dependency. This target implements sharing, and app-intent extraction is not expected there; the app's extraction runs separately. No warnings were suppressed. Simulator tooling also emits OS-build parsing, duplicate system accessibility-class, and runner launch-screen warnings; these are recorded in the UI logs and do not imply the app's launch-screen configuration failed.

Final-source unsigned archives also passed after the celebration cleanup. Final simulator build-for-testing passed (`/tmp/gsd-readiness-final-build.log`), and Catalyst Release passed (`/tmp/gsd-readiness-mac-effects.log`). Icons were compiled into the inspected bundles; no ATS exception dictionary was present.

### Runtime interaction

- iPhone 18 Pro / iOS 27.0: first launch, Skip onboarding, signed-out capture using `!!`, task visible after relaunch, cancelled title discarded, edited title saved after relaunch — PASS in `/tmp/gsd-readiness-iphone.xcresult`.
- iPad Pro 13-inch (M5) / iOS 27.0: same journey — PASS in `/tmp/gsd-readiness-ipad.xcresult`.
- Expanded lifecycle (Complete, Show Completed, Delete, Undo) passed on iPhone 18 Pro / iOS 27.0 and iPhone 17 Pro / iOS 26.5 before the final animation cleanup. Result bundles: `/tmp/gsd-readiness-iphone-lifecycle.xcresult` and `/tmp/gsd-readiness-ios26.xcresult`.
- Final-source iPhone 17 Pro / iOS 26.5 lifecycle test passed again, including completion, deletion, and Undo: `/tmp/gsd-readiness-ios26-final.xcresult`. Its result screenshot is exported in `build/release-readiness/ios26-final/`.
- The initial expanded iPad run stalled waiting for automation idle around a context menu; interrupted after several minutes and rebooted only the disposable QA iPad. This run is not a pass. It does not establish an app hang by itself; the basic iPad edit/persistence test had passed. A fresh final run reproduced the context-menu automation idle stall and was interrupted after more than three minutes; its menu-open screenshot is saved in `build/release-readiness/ipad-context-menu.png`. Completion/Delete/Undo through this iPad menu remain unverified. The animation lifetime fix did not establish a resolution for this separate automation problem.
- Existing iPhone dark-mode screen walk passed (14 captures): `/tmp/gsd-readiness-dark.xcresult`. Inspected editor, dashboard, Settings, and keyboard/capture screenshots; no new blocking visual defect observed in those views. Other captures remain artifacts rather than a full accessibility certification.
- Inspected iPhone and iPad screenshots: existing editorial theme, compact tabs and regular sidebar/matrix render without an observed blocking layout defect in these captures. This is limited to the captured sizes and states.
- Unsigned Catalyst app launched; screenshot shows the non-editable storage-recovery screen. Normal task journeys could not be exercised. Lack of valid signing is a limitation; the exact storage-open error was not instrumented, so do not classify this screenshot alone as proof of a shipping database defect.
- Catalyst menu contents were inspected through macOS accessibility before and after the fix. This verifies menu structure, not execution of every command.

Screenshots and exported attachments are in `build/release-readiness/` (ignored build output). Original result bundles and build logs are under `/tmp`; retain them before cleaning temporary files.

### Static inspection

- Persistence uses GRDB/SQLite; store mutations enqueue optional sync work. Widget snapshots and share outbox use the App Group. Local task functionality needs no account.
- Implemented integrations include OAuth providers, account deletion, PocketBase REST/SSE, optional feedback, local notifications, background refresh, widgets, App Intents, Spotlight, URL routing, share import, and optional page-title enrichment. No StoreKit purchase flow was found; purchase/restore tests are not applicable to this checkout.
- Catalyst declares sandbox, outbound network, user-selected document access, and the App Group. iOS and extensions declare their shared group. No entitlement or signing identity was changed.
- Privacy manifests cover UserDefaults and file timestamps; the app declares linked account email, user ID, and user content for app functionality. Feedback and optional title fetching require owner confirmation against actual server behavior and App Store Connect answers.
- Settings has a privacy link, support email, and in-app account deletion. Deletion erases remote tasks before deleting the account and signing out. Live deletion was not performed.
- Title enrichment is off by default, disclosed in Settings, and requests the shared page via URLSession with an 8-second request timeout and bounded HTML read. The published privacy policy says data leaves only for sync/feedback and identifies sign-in providers as the only third parties. It omits these optional third-party web requests. This is a confirmed disclosure mismatch for owner review, not a claim of a confirmed App Review rejection.

## Submission requirements checked against Apple

Apple's [submission guidance](https://developer.apple.com/app-store/submitting/) currently recommends Xcode 27 and lists the next SDK floor as April 2027. This checkout builds with SDK 27.1; no SDK-floor blocker was found. The guidance also requires completed product-page/privacy information and age-rating answers. Their actual App Store Connect state was not accessed.

Apple requires apps with account creation to offer [in-app account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion). The source contains that flow; a controlled test account is still required to verify it end to end. [Privacy manifests](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk) must be accurate as well as present. Owner approval is required before editing declarations.

The [live GSD privacy policy](https://gsdtaskmanager.com/privacy/) was reachable and dated October 14, 2026. Its title-fetching omission is described above. Support email delivery, listing screenshots, review notes, age ratings, pricing, and App Store Connect privacy answers were not verified. No performance measurements or physical-device performance claims were made.

## Remaining work, ordered by release impact

1. **Signing / Mac runtime / distribution validation.** Development signing and basic Mac runtime were subsequently verified (see signed Mac follow-up below); the following was the original checklist, with distribution and extension-host checks still outstanding. In Xcode → Settings → Accounts → the owner team, reconcile the development certificate with the existing Catalyst app and share-extension profiles. Do not change bundle IDs or capabilities. Rebuild Release for Mac Catalyst using valid existing signing. Launch and confirm the matrix opens; create/edit/complete/delete/Undo a disposable task; quit and reopen. Exercise minimum/large window sizes, focus and keyboard traversal, ⌘N/⌘K/⌘1–4/⌘R, Settings, About dismissal, and Help. Install the signed build in `/Applications` and share a URL and plain text from Safari to verify extension registration and ingestion.
2. **Publish the prepared privacy correction and confirm App Store Connect answers.** The local policy update is complete (see October 18 evidence). Publication is still pending. Confirm deployed feedback controls/retention and App Store Connect answers against operational reality; client/source checks are not live-server proof.
3. **Signed archives.** Archive iOS and Catalyst with the intended distribution profiles, then use Organizer → Validate App. Do not upload or submit without a separate instruction. The unsigned archives in this report cannot pass distribution-signature checks.
4. **Controlled account and OS integrations.** With a disposable account and task, test each offered provider, cancellation/expired session, sync between two clients, offline edits and reconnection, and account deletion while retaining versus erasing local data. Test offline failure without losing data. Verify notifications allowed/denied, notification tap routing, widget refresh/deep links, share extension, Spotlight, Shortcuts, and background refresh on hardware. No feedback was sent during this pass.
5. **Physical accessibility and supported layouts.** The iPad context-menu automation gap was closed on October 18 (see follow-up evidence above). Continue with hardware checks: On iPhone and iPad, check VoiceOver order/custom actions, all accessibility Dynamic Type sizes, light/dark, Reduce Motion, keyboard avoidance, supported rotation, narrow iPad multitasking, and permission-denied states. Repeat core local journeys with Airplane Mode enabled. The automated signed-out tests did not disable networking and are not an end-to-end network-isolation test.
6. **Upgrade and listing.** Preserve/export an older installation's data, install the candidate over it, and verify active/archive/trash/views/settings plus relaunch. Existing migration tests do not replace a real installed-app upgrade. Review final device screenshots, support/privacy URLs, age ratings, accessibility claims, review notes, and demo credentials in App Store Connect.

## Reproduction

From the repository root:

```sh
swift test --package-path GSDKit
xcodebuild -project GSD.xcodeproj -scheme GSD -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GSD.xcodeproj -scheme GSD -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
# On a disposable simulator only; use the disposable QA simulator retained from this pass:
TEST_RUNNER_RELEASE_QA=1 xcodebuild test -project GSD.xcodeproj \
  -scheme GSDScreenshots -configuration Release \
  -destination 'platform=iOS Simulator,id=F27B6EF7-C8D7-4582-ACB9-962B7DAE0751' \
  -only-testing:GSDScreenshotTests/ReleaseReadinessTests CODE_SIGNING_ALLOWED=NO
```

## Changed files

- `GSDKit/Sources/GSDModel/TaskImporter.swift`
- `GSDKit/Tests/GSDModelTests/TaskImporterTests.swift`
- `App/Mac/GSDMenuCommands.swift`
- `App/Effects/ConfettiView.swift`
- `App/Editor/TaskEditorView.swift`
- `App/Matrix/QuadrantSection.swift`
- `App/Matrix/QuadrantCell.swift`
- `ScreenshotTests/ScreenshotTests.swift`
- `tasks/todo.md`
- This report.

The October 18 follow-up additionally changes the marketing repository's `app/privacy/page.tsx`. Its existing lockfile and gallery changes are not part of this work.


## Signed Mac verification — October 18

- Checkout: `main` at `9a3d426`, with the uncommitted readiness fixes preserved. No signing configuration was changed during this verification.
- Development-signed Debug build: PASS (`/tmp/gsd-signed-mac-verification.log`). Development-signed universal Release build: PASS (`/tmp/gsd-signed-mac-release.log`). Both app and share extension signed with the existing Apple Development identity and their Catalyst provisioning profiles.
- `codesign --verify --deep --strict`: PASS, including embedded share extension. Release bundle: `/tmp/gsd-signed-mac-verification/Build/Products/Release-maccatalyst/GSD.app`. This is development signing, not distribution/archive validation.
- Release runtime, inspected through macOS accessibility: matrix opens instead of storage recovery; New Task editor opens; a uniquely labeled QA task saves and appears in the matrix; deletion displays confirmation and Undo; after quit/relaunch the matrix opens and the deleted task remains absent. Undo and edit/save/cancel were not exercised in this signed Release run.
- Settings, Find, Help and About open; About shows 3.0.0 (34), its named close button dismisses it; one View menu remains. Window resizing to 1200×850 exposes the desktop sidebar; original 555×663 size restored. These are accessibility-tree/interaction checks, not a complete visual or VoiceOver audit.
- Important session distinction: Debug Settings showed signed out, but Release restored an existing signed-in session. This was detected after creating `Mac Release QA 20261018`; that task was deleted and its absence verified after relaunch. No further task mutations or manual sync were performed. The QA task may have synced and remains subject to normal trash retention; no existing tasks or account settings were changed. Live sync correctness is not established by this run.
- Remaining Mac gates: signed distribution archive/Organizer validation, share extension invocation from a host application, full edit/complete/Undo journey in a disposable signed account or isolated store, and keyboard/VoiceOver/visual checks. No upload, publication, or commit performed.

### Undo clarification and runtime follow-up

The reported missing deletion message was clarified by the owner: the action was Complete, not Delete. Completion has no deletion Undo toast; use Show Completed and toggle completion again. Individual task-menu deletion was visually verified on the original signed Release build, including clicking Undo and finding the restored QA task after relaunch. An initial capture caught the entrance transition and was incorrectly interpreted as persistent clipping; a settled capture corrected that interpretation. The experimental safe-area change was removed completely. QA tasks were deleted after testing; normal Trash retention applies. No product code change was retained from this investigation. Edit/select bulk deletion is a separate path without this notification; it was not established as the owner's issue or changed here.


## App Store distribution preparation — October 18

Owner authorized distribution archiving, validation, and upload to App Store Connect after deploying the privacy update. A fresh uncached policy fetch confirms the October 18 shared-link title disclosure is live. The marketing version was already 3.0.0; build 34 was incremented to 35 via the version script, regenerating the Xcode project. All app and extension versions match.

- iOS archive: `/tmp/gsd-appstore-ios-35.xcarchive`; distribution IPA: `/tmp/gsd-appstore-ios-35-export/GSD.ipa`.
- Mac Catalyst universal archive: `/tmp/gsd-appstore-mac-35.xcarchive`; distribution installer: `/tmp/gsd-appstore-mac-35-export/GSD.pkg`.
- Both archives and App Store distribution exports succeeded. Distribution summaries confirm Apple Distribution certificates, expected extension versions and entitlements, and `get-task-allow=false`. Mac installer signature and nested archive code signatures verified.
- Apple validation: both artifacts returned `VERIFY SUCCEEDED with no errors`. Logs: `/tmp/gsd-appstore-ios-35-validation.log` and `/tmp/gsd-appstore-mac-35-validation.log`.
- Both uploads returned `UPLOAD SUCCEEDED with no errors`. iOS delivery UUID: `bd715725-5efc-4eec-a9ec-599f731dd420`; Mac delivery UUID: `0d39fac2-1d19-4899-b47d-40971ba58bf9`. Upload logs: `/tmp/gsd-appstore-ios-35-upload.log` and `/tmp/gsd-appstore-mac-35-upload.log`.
- The initial App Store Connect API read did not yet list build 35. The owner subsequently confirmed that both iOS and Mac apps finished processing in App Store Connect. This processing completion is owner-confirmed; no additional API verification was performed. Neither app was submitted for review or released during this work.
- The owner authorized committing the version bump and this release report and opening a pull request. Remaining gates are final device/account checks and App Store Connect listing, build selection, and review submission.


## 3.5.0 build 36 upload to App Store Connect, October 25

The owner asked to bump to 3.5.0 and release both platforms. Before the run, a read of the App Store Connect API showed 2.2.0 as the live version on iOS and macOS (both released July 6), no 3.0.0 version record, and build 35 processed but never attached to a version. Seven PRs (#26 to #32, the iPhone Duo readiness fixes and the large Today's Focus widget) had merged after build 35 with no version change. The bump jumps to 3.5.0 rather than 3.0.1 on the owner's call.

- `scripts/release.sh set 3.5.0 36` rewrote project.yml from 3.0.0 (35) to 3.5.0 (36) and regenerated the Xcode project, so project.pbxproj carries the new values; App/Info.plist references the build settings and did not change. All app and extension versions match.
- iOS: the Release archive for a generic iOS device, the App Store export, and the upload all succeeded. `UPLOAD SUCCEEDED with no errors`, delivery UUID `24370c4e-37ef-4c0c-a141-26f61f8e80a0`, 11,039,106 bytes, 2026-10-26 02:34 UTC. Log: `build/release-3.5.0-ios.log` (build/ is gitignored, so the log is local only).
- Mac Catalyst: `scripts/release.sh --mac --no-bump` ran after the iOS run. The universal Release archive, the App Store export (.pkg), and the upload all succeeded. The distribution summary shows Apple Distribution certificates and the Mac Catalyst Team Store profiles for the app and the share extension, with symbols included. `UPLOAD SUCCEEDED with no errors`, delivery UUID `c0e90ef0-d9d9-4207-9a9a-457a41462e66`, 12,808,285 bytes, 2026-10-26 02:36 UTC. Log: `build/release-3.5.0-mac.log`; the .pkg and its summary stay in `build/export/`.
- The Mac run reuses `build/GSD.xcarchive` and `build/export`, so the iOS archive and .ipa are no longer on disk. The upload record above stands on the altool result.
- Processing: a read of the App Store Connect API after the uploads lists build 36 for 3.5.0 on both platforms with processing state VALID, the iOS build within a minute of its upload and the Mac build within four. No owner confirmation was needed this time.
- `whatsnew.txt` now carries the 3.5 copy. It is cumulative since 2.2.0, the live version: the iOS 27 and macOS 27 refresh, the share and sync changes from PRs #19 to #23, the accessibility sizing from #24, and the iPhone Duo work.
- Not done in this run, and owner-owed in App Store Connect: create the 3.5.0 version for iOS and for macOS, attach build 36 to each, paste the What's New copy, and submit for review. Export compliance resolves itself from `ITSAppUsesNonExemptEncryption` in the plist. Build 35 stays in App Store Connect unused.


## 3.6.0 build 37 upload to App Store Connect, October 26

The owner asked to build both platforms, bump the version and build appropriately, and deploy to the iOS and Mac App Stores. Before the run, a read of the App Store Connect API showed 2.2.0 still live on iOS and macOS, with no 3.x version record on either platform. Both 3.5.0 build 36 uploads had processed to VALID, and neither was attached to a version yet. One PR (#34, the native Saved library with notes and web sync) had merged after build 36. A new feature calls for a minor bump, so the version moves from 3.5.0 (36) to 3.6.0 (37).

- `scripts/bump-version.sh minor` rewrote project.yml and regenerated the Xcode project, so project.pbxproj carries the new values. The app, the share extension, and the widgets all read 3.6.0 (37) in the iOS archive. The Mac archive embeds the app and the share extension, both at 3.6.0 (37).
- `swift test` in GSDKit before the bump: 288 tests in 33 suites pass.
- iOS: `scripts/release.sh --no-bump` ran the Release archive for a generic iOS device, the App Store export, and the upload. `UPLOAD SUCCEEDED with no errors`, delivery UUID `879aeed0-d021-44d1-8279-19437b3834a1`, 11,205,383 bytes, 2026-10-26 21:31 UTC. Log: `build/release-3.6.0-ios.log` (build/ is gitignored, so the log is local only).
- Mac Catalyst: `scripts/release.sh --mac --no-bump` ran after the iOS run. The universal Release archive, the App Store export (.pkg), and the upload all succeeded. `UPLOAD SUCCEEDED with no errors`, delivery UUID `0679d942-cf38-4f2c-a775-c729c63a0f57`, 13,138,958 bytes, 2026-10-26 21:34 UTC. Log: `build/release-3.6.0-mac.log`; the .pkg and its summary stay in `build/export/`.
- The Mac run reuses `build/GSD.xcarchive` and `build/export`, so the iOS archive and .ipa are no longer on disk. The upload record above stands on the altool result.
- Processing: a read of the App Store Connect API after the uploads lists build 37 on both platforms with processing state VALID, each within three minutes of its upload.
- `whatsnew.txt` now opens with "GSD 3.6 adds Saved" and leads both platform sections with a Saved bullet. The rest of the copy stays cumulative since 2.2.0, the live version.
- Not done in this run, and owner-owed in App Store Connect: create the 3.6.0 version for iOS and for macOS, attach build 37 to each, paste the What's New copy, and submit for review. Export compliance resolves itself from `ITSAppUsesNonExemptEncryption` in the plist. Builds 35 and 36 stay in App Store Connect unused.


## 3.6.1 build 38 upload to App Store Connect, October 27

The owner asked to build and deploy the iOS and Mac versions with the Saved sync fix (PR #36, merged as `4352ce1`) and to deploy the web version by hand. Before the run, a read of the App Store Connect API showed 3.6.0 as READY_FOR_SALE on iOS and macOS, both version records created October 26. A fix on a live version calls for a patch bump, so the version moves from 3.6.0 (37) to 3.6.1 (38).

- `swift test` in GSDKit on main before the bump: 738 tests across the package suites pass.
- `scripts/bump-version.sh patch` rewrote project.yml and regenerated the Xcode project, so project.pbxproj carries the new values. Log: `build/release-3.6.1-bump.log`.
- iOS: `scripts/release.sh --no-bump` ran the Release archive for a generic iOS device, the App Store export, and the upload. `UPLOAD SUCCEEDED with no errors`, delivery UUID `f0778687-3597-4c0e-83e1-d30f95304a41`, 11,206,423 bytes, finished 2026-10-27 18:34 UTC. Log: `build/release-3.6.1-ios.log` (build/ is gitignored, so the log is local only).
- Mac Catalyst: `scripts/release.sh --mac --no-bump` ran after the iOS run. The universal Release archive, the App Store export (.pkg), and the upload all succeeded. `UPLOAD SUCCEEDED with no errors`, delivery UUID `b9b864bd-03f1-49c2-83b8-82633e9dbe6a`, 13,141,509 bytes, finished 2026-10-27 18:36 UTC. Log: `build/release-3.6.1-mac.log`.
- The Mac run reuses `build/GSD.xcarchive` and `build/export`, so the iOS archive and .ipa are no longer on disk. The upload record above stands on the altool result.
- Processing: a read of the App Store Connect API at 18:38 UTC lists build 38 for 3.6.1 as VALID on macOS and VALID on iOS.
- `whatsnew.txt` now leads with "GSD 3.6.1 fixes Saved sync" on both platforms and summarizes 3.6 in one paragraph. With 3.6.0 live, the notes no longer need to run cumulative from 2.2.0.
- Submission: the owner created the 3.6.1 version for iOS and for macOS, attached build 38 to each, and submitted both for review the same afternoon. A read of the App Store Connect API at 18:45 UTC shows both versions as WAITING_FOR_REVIEW.


## 3.6.3 build 39 upload to App Store Connect, October 28

The owner asked to ship the iPad and Mac matrix fix: undo the stray Xcode project changes, refresh the App Store screenshots, bump to 3.6.3 with the next build number, push, and upload both platforms. Before the run, a read of the App Store Connect API showed 3.6.1 as READY_FOR_SALE on iOS and macOS, with build 38 as the newest build. No 3.6.2 was ever uploaded, because the owner asked for 3.6.3 directly and the stray Xcode bump to 3.6.2 (39) was discarded.

- The fix is `f8e57d6`, recorded in `docs/2026-10-28-matrix-card-stretch.md`. On the branch, `swift test` passed 288 tests in 33 suites, and the iPhone 17, iPad Pro 13-inch (M5), and Mac Catalyst builds succeeded.
- Screenshots (`8e30367`): `ScreenshotTests` ran on iOS 27.0 in light and dark. The 6.5-inch set comes from the iPhone 18 Pro Max, resized to 1284x2778. A new 6.3-inch set comes from the iPhone 17 at 1206x2622. The 13-inch iPad set comes from the iPad Pro 13-inch (M5), rotated to 2752x2064. Every file was checked for size and has no alpha channel. The Mac App Store screenshots were not recaptured, because that walk drives the real screen.
- `scripts/bump-version.sh set 3.6.3 39` rewrote project.yml and regenerated the Xcode project (`cdf27bf`). The app and both extensions read 3.6.3 (39).
- iOS: `scripts/release.sh --no-bump` ran the Release archive for a generic iOS device, the App Store export, and the upload. `UPLOAD SUCCEEDED with no errors`, delivery UUID `d45686c4-97fb-47e2-a53a-6f952d9be79b`, 11,208,421 bytes, finished 2026-10-29 03:57 UTC. Log: `build/release-3.6.3-ios.log` (build/ is gitignored, so the log is local only).
- Mac Catalyst: `scripts/release.sh --mac --no-bump` ran after the iOS run. The universal Release archive, the App Store export (.pkg), and the upload all succeeded. `UPLOAD SUCCEEDED with no errors`, delivery UUID `2a502031-36f6-4bcd-8c7b-732856d28d90`, 13,144,662 bytes, finished 2026-10-29 04:00 UTC. Log: `build/release-3.6.3-mac.log`.
- The Mac run reuses `build/GSD.xcarchive` and `build/export`, so the iOS archive and .ipa are no longer on disk. The upload record above stands on the altool result.
- Processing: a read of the App Store Connect API lists build 39 for 3.6.3 as VALID on iOS at 04:00 UTC and on macOS at 04:02 UTC.
- `whatsnew.txt` leads with the matrix fix on both platforms and keeps one paragraph on Saved.
- Not done in this run, and owner-owed in App Store Connect: create the 3.6.3 version for iOS and for macOS, attach build 39 to each, paste the What's New copy, upload the new iPhone and iPad screenshot sets from `screenshots/`, and submit for review. Export compliance resolves itself from `ITSAppUsesNonExemptEncryption` in the plist.
