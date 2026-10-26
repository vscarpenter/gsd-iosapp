# Saved uses task placement and the shared description

Date: 2026-10-26
Status: Accepted
Deciders: Vinny Carpenter, Codex

## Context

The web app already supports Saved (web ADR 0018). The owner wants native Saved
with short annotations, return to matrix and web sync. Keeping reference items in
active quadrants obscures the question the matrix should answer: what to work on.

## Decision

Keep a Saved item as the same task row, with nullable `savedAt` locally and the
existing `saved_at` text field in PocketBase. An empty wire string clears placement.
Use `description` for notes, with the web's 600 UTF-16-unit limit. The v7 migration
adds nullable placement to tasks, archive and trash. Add no dependencies or backend
migrations.

TaskStore remains the mutation boundary. Full task storage feeds sync, backups,
account safety and dependency graphs. Explicit matrix/filter/analytics/reminder/
widget/suggestion paths exclude Saved. Saved prerequisites still block dependents.
Save and return preserve identity; neither completes a task nor spawns recurrence.
Return reviews quadrant/date and resets reminder delivery/snooze state. Note writes
read the latest row and change only description; existing last-write-wins sync
continues to resolve competing full-record updates.

## Consequences and alternatives

Saved remains offline-capable and round-trips through both clients. It belongs in
Browse/Library, with global search routing Saved results to that surface. Long-form
notes, separate note entities and a fifth active quadrant are outside this scope.
Separate note tables or a new bookmark entity would duplicate task context and
require another sync contract. Keeping a bookmark flag without removing the item
from active views would leave the owner's original matrix-clutter problem intact.

Older native versions do not understand Saved placement and can show or overwrite
Saved records as ordinary tasks. Use this version or the current web client for
Saved; this change does not retrofit older installed binaries.
