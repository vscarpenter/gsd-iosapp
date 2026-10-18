import Foundation
import GSDModel
import GSDStore
import GSDSnapshot

/// The one place the app drains the Share-Extension outbox, so the four triggers (launch,
/// foreground, the Darwin signal from a running app, and the background refresh) cannot drift
/// in how a capture lands. Trivial glue over the unit-tested `ShareInbox`; verified by build + smoke.
///
/// Two landings: a capture the extension already pushed to PocketBase goes through
/// `TaskStore.ingestSynced` (no sync item — the server has it); anything else goes through
/// `TaskStore.create` (enqueued for push as before).
@MainActor
final class ShareInboxDrainer {
    private let inbox: ShareInbox
    private let store: TaskStore
    private let titleEnricher: ShareTitleEnricher

    init(inbox: ShareInbox, store: TaskStore, titleEnricher: ShareTitleEnricher) {
        self.inbox = inbox
        self.store = store
        self.titleEnricher = titleEnricher
    }

    /// `enrichTitles: false` in the background-refresh window: the enricher's fetch is
    /// fire-and-forget and the database re-suspends before it would land.
    func drain(enrichTitles: Bool = true) async {
        await inbox.drain(
            create: { task in
                try await store.create(task)
                if enrichTitles { titleEnricher.schedule(for: task) }   // upgrade a URL-derived title
            },
            ingestPushed: { task in
                try await store.ingestSynced(task)
                if enrichTitles { titleEnricher.schedule(for: task) }   // a later edit syncs as an update
            })
    }
}
