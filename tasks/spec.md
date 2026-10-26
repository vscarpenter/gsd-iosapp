# Saved on iOS

## Goal and authority

Implement the approved Saved behavior from the web app and the owner's request
for the iOS follow-up: short notes, return to matrix and bidirectional web sync.
The approved design covers this spec, plan and implementation in one pass.

## Inputs and outputs

- Add optional `Task.savedAt: Date?`, persisted on existing task rows and carried
  as `savedAt` in backups and `saved_at` in PocketBase. Missing means active;
  return writes an empty wire string to clear placement remotely.
- Move an incomplete task to Saved with its identity, notes, dates, flags, tags,
  subtasks, recurrence and dependencies intact. Reject a running timer.
- Expose Saved in iPhone Browse and the regular-width Library sidebar. Search
  titles and notes, edit short notes in the existing description (600 UTF-16
  units, matching web), and return after reviewing quadrant and optional date.
- Keep Saved outside the matrix, active smart views, analytics, widgets, badges,
  reminders, Spotlight active suggestions and active App Intent results. Retain
  the full stored graph for dependency checks, backup, reset/import and sync.

## Constraints and edge cases

- Offline-first; sync remains optional. No new backend schema or production
  mutations. The deployed additive Saved field is already available.
- Save and return are placement transitions, never completion or deletion; no
  recurrence is spawned. Completion and timers require return to matrix first.
- Read current stored state before transitions and note writes. Do not resurrect
  deleted rows or overwrite unrelated edits made through web sync. Ordinary edits
  must retain current Saved placement. Handle stale editors and remote returns.
- Preserve Saved in trash/restore and JSON round trips. Migrate existing local
  data without changing records. Saved prerequisites continue to block work.
- Use existing SwiftUI navigation, colors, typography, error handling and isolated
  demo/test infrastructure. Respect Dynamic Type, Reduce Motion and VoiceOver.

## Out of scope

Long-form notes, new organization systems, Android changes, App Store upload,
production data probes and unrelated refactors.

## Acceptance criteria and test stubs

1. Legacy tasks and databases migrate as active; saved tasks survive restart,
   backup, restore and trash. Model/store/migration/backup tests.
2. Saving and returning preserve context and enqueue the corresponding sync
   payload; invalid/stale actions fail safely. Store transition and timer tests.
3. Native notes obey the web limit and change only description on the latest
   row. Empty, Unicode, over-limit and concurrent-edit tests.
4. Active surfaces omit Saved; dependency checks retain Saved prerequisites.
   Filter, analytics, reminder, widget and mutation tests.
5. Web wire payload -> iOS pull -> native notes/return -> outgoing web-compatible
   payload retains identity and placement. Mapper, pull/push and cross-client
   fixture tests, plus a disposable local PocketBase round trip where available.
6. A native UI walk saves a task, edits notes, finds it, returns it to the selected
   quadrant and observes the same identity. Verify iPhone/iPad light and dark,
   compile Mac Catalyst, and capture fresh simulator evidence.
