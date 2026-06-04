import Foundation
import GSDModel

/// Drains the share outbox through the app's `create` path (spec §3, §4.1). `@MainActor` and
/// single-flight so the launch + foreground drains that fire near-simultaneously at cold start
/// don't double-create. GRDB-free: the app injects `TaskStore.create` as the `create` closure.
@MainActor
public final class ShareInbox {
    private let store: ShareOutboxStore
    private let now: () -> Date
    private let newID: () -> String
    private var isDraining = false

    public init(store: ShareOutboxStore,
                now: @escaping () -> Date = { Date() },
                newID: @escaping () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }) {
        self.store = store
        self.now = now
        self.newID = newID
    }

    /// Single-flight (`isDraining` set synchronously before any `await`). Each pending capture
    /// is built into a valid `Task` and handed to `create`; the file is removed only after
    /// `create` succeeds. A transient `create` throw keeps the file for the next drain.
    public func drain(create: (Task) async throws -> Void) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        for item in store.pending() {
            let task = SharedCaptureBuilder.task(from: item.capture, id: newID(), now: now())
            do {
                try await create(task)
                store.remove(id: item.id)        // only after success
            } catch {
                continue                          // transient failure → keep file, retry next drain
            }
        }
    }
}
