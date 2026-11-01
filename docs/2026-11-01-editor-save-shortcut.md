# Save the task editor with ⌘S

Date: 2026-11-01. Branch: `feat/editor-save-shortcut`. Issue #39 asked for a keyboard shortcut to save the task being edited, either ⌘↩ or ⌘S.

## Decision

⌘S saves, on the visible Save button in `TaskEditorView`. It's the standard Save key on Mac and iPad, and it appears in the iPad's hold-⌘ overlay. ⌘↩ isn't included. A button takes one shortcut, so it would need a second hidden button, and the Notes field is multi-line. It's cheap to add later if anyone asks.

The shortcut is on the task editor only. The Saved and smart view editors also have a Save button and don't get ⌘S, because the issue doesn't cover them. There's no File menu item either. The Field Guide is where people find it.

## What a key press changed

A key press can do things a tap can't, and `canSave` now covers them.

- **Behind other presentations.** With only the shortcut added, ⌘S fired behind the "Discard changes?" alert and behind the dependency picker, on both simulators it ran on. It saved a draft the user was being asked to discard. Save is now disabled in both states.
- **Repeats.** `save()` starts an async task and had no guard. A second run wouldn't duplicate the row, because `create` upserts on the same id, but it would queue a second sync operation and move `createdAt`. `isSaving` now blocks it, as it does in the Saved and smart view editors. All three failure paths reset it, or a failed save would lock the button.

The Field Guide footnote said shortcuts are suppressed while typing. That was false, not just out of date: ⌘K opened the palette from the capture bar on the iPhone simulator. The sentence is gone.

## Test

`ScreenshotTests/EditorSaveShortcutTests.swift`, gated on `TEST_RUNNER_EDITOR_SAVE_SHORTCUT=1`. It launches with `--demo-clock`, so each run gets an empty in-memory store and no session.

```
TEST_RUNNER_EDITOR_SAVE_SHORTCUT=1 xcodebuild test -project GSD.xcodeproj -scheme GSDScreenshots \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:GSDScreenshotTests/EditorSaveShortcutTests
```

Red was seen in stages. Before the shortcut, the three save tests failed at the assertion that ⌘S closes the editor. With only the shortcut, those passed and the alert and picker tests failed. The failed-save test was seen red by removing its `isSaving` reset for one run.

The repeat guard has no test that proves it. A UI test can't see the sync queue, and `App/` has no unit test target.

## Still open

- **The simulators drop the first ⌘ key after a launch.** It happened with ⌘N, ⌘K, and ⌘S, including with no production change for ⌘N and about 7 seconds after launch for ⌘K. The second press works. It looks like a simulator quirk, but the cause isn't diagnosed. `testSavesOnTheFirstPressAfterOpeningByTap` covers it on the Mac, and a real iPad needs a hand check.
- **Esc does nothing in an edited task editor** on the iPad and iPhone simulators, though the Field Guide says it closes any sheet or drawer. Cancel has no `.cancelAction`. Left alone here, since it's outside the issue.
- **Dead-key and IME composition and a held ⌘S** can't be driven by XCUITest. Both need a hand check.

On the simulators, ⌘N and ⌘K behind an open editor with edits did nothing, and the draft survived. The Mac routes those through the menu bar, which wasn't checked.
