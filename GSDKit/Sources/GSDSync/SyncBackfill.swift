import GSDModel

/// What the backfill copies onto a local row that's about to win the pull (top three spec C4-4).
/// That row goes out on the next push, so a synced field its build never read would go out empty
/// and clear the server's value (`sprint/findings/saved-at-exposure.md`).
enum SyncBackfill {
    /// The contract that first synced `saved_at`.
    static let savedAtContract = 3

    /// `local` plus each synced field it lacks, the remote has, and the stored contract predates.
    /// The gate matters: an empty field means "never read" only on a build older than the field.
    /// Pulled under its contract, it's a real Return that may not have pushed yet. The copy keeps
    /// `updatedAt` and every other field. Nil when nothing changes, so the caller writes nothing.
    static func fillingUnreadFields(of local: Task, from remote: Task, storedVersion: Int) -> Task? {
        var filled = local
        if storedVersion < savedAtContract, local.savedAt == nil, remote.savedAt != nil,
           SavedPlacement.canSave(local) {
            filled.savedAt = remote.savedAt
        }
        return filled == local ? nil : filled
    }
}
