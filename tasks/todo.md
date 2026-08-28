# Cross-platform parity fixes — status

Branch: `fix/cross-platform-parity` (same name in gsd-taskmanager).

## Done

- [x] **Backup envelope parity.** String version (decode accepts legacy Int), plus
      archivedTasks / deletedTasks / smartViews / notificationSettings /
      archiveSettings / appPreferences. `FilterCriteria` decodes leniently;
      backups write the derived `quadrant`. ADR: `docs/2026-08-28-trash-and-backup-parity.md`.
- [x] **Trash.** v6 `deletedTasks` table, `TrashRepository`, `TrashRetention`
      (30 days, start-of-day anchor), Settings → Trash, sweep alongside auto-archive.
      Wire behaviour unchanged: delete still enqueues `.delete` first; restore
      enqueues `.create`.
- [x] **Apple identity.** Warns on every Apple sign-in, not only private-relay.
      Provider persisted so the note survives relaunch.

Verification: `swift test` 594 passing; iPhone, iPad and Mac Catalyst all build.

## Resuming from here

**Next:** nothing outstanding in this repo for these four findings.

**Blocked / needs the owner:**
- **PocketBase account linking.** Adding Apple to the web (done) stops the provider
  choice being a one-way trap, but it does NOT merge accounts already split across
  providers. That needs the `users` collection set to link OAuth2 identities by
  verified email, in the PocketBase admin UI — not in `docker/pb_migrations`, and
  not something either client can do.

**Deliberate follow-ups (not regressions):**
- `TaskImporter.maxImportTasks` counts `tasks` only; a lossless backup can exceed
  the 10,000 guard. Web has the same gap. Its own change.
- The task editor offers 8 reminder options while `NotificationSettings.allowedReminders`
  defines 5 (adds None / At time of event / 5 minutes). Internal to iOS and
  pre-existing; the web control added in the other repo renders off-list values
  rather than snapping, so nothing is lost meanwhile.

**Assumptions made:**
- `apple` is configured on the live PocketBase server. Evidence: `AuthService.signIn`
  resolves providers from the server's auth-methods endpoint and the iOS Apple
  button works today.
- Only custom smart views travel in a backup — both clients derive the nine
  built-ins at read time and never store them.
