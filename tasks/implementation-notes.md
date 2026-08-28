# Implementation notes — cross-platform parity fixes

## Tactical deviation: trash moved ahead of the envelope wiring (2026-08-28)

The approved plan sequenced envelope → Apple → reminder → trash, with `deletedTasks`
folded into the envelope work "already landed".

That ordering does not hold. `TaskStore.restoreCompanionStores` has to write a restored
`deletedTasks` array somewhere, and until the trash store exists there is nowhere to put
it. Shipping the envelope first would mean a build that parses `deletedTasks` off a web
backup and silently drops it — precisely the bug being fixed, reintroduced one layer down.

So: trash lands first, then the envelope wiring closes over it. No scope change; only the
order within the same approved set.

## Follow-ups deliberately not taken here

- `TaskImporter.maxImportTasks` counts `tasks` only. Now that a backup carries
  `archivedTasks` and `deletedTasks`, the 10,000 guard admits more rows than it claims.
  The web has the identical gap (`MAX_IMPORT_TASKS`). Changing a security limit did not
  belong inside a compatibility fix — tracked for its own change.
- The iOS task editor offers 8 reminder options while `NotificationSettings.allowedReminders`
  defines 5 (adds None / At time of event / 5 minutes). That inconsistency predates this
  work and is internal to iOS; the web control added here renders any off-list stored
  value rather than snapping it, so nothing is lost in the meantime.
