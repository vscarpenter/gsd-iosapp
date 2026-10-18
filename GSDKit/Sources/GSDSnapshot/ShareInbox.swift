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
    /// is built into a valid `Task` and handed on; the file is removed only after the handler
    /// succeeds. A transient throw keeps the file for the next drain.
    ///
    /// - `create`: the normal path (the store's `create`, which enqueues a sync push). Used for
    ///   captures the extension did not push — under the extension's `taskID` when it chose one,
    ///   so a push that timed out but still landed becomes an update, not a duplicate.
    /// - `ingestPushed`: captures the extension already pushed (`remoteRecordID` set). The task is
    ///   rebuilt exactly as pushed (`SharedCapture.pushedTask`) and must land locally WITHOUT a
    ///   sync item — the server already has it.
    public func drain(create: (Task) async throws -> Void,
                      ingestPushed: (Task) async throws -> Void) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        for item in store.pending() {
            let capture = item.capture
            do {
                if capture.remoteRecordID != nil, let pushed = capture.pushedTask() {
                    try await ingestPushed(pushed)
                } else {
                    let task = SharedCaptureBuilder.task(from: capture, id: capture.taskID ?? newID(), now: now())
                    try await create(task)
                }
                store.remove(id: item.id)        // only after success
            } catch {
                continue                          // transient failure → keep file, retry next drain
            }
        }
    }
}
