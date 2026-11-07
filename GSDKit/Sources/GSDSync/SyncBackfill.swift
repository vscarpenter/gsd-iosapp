import GSDModel

/// What the backfill copies onto a local row that's about to win the pull (top three spec C4-4).
/// That row goes out on the next push, so a synced field its build never read would go out empty
/// and clear the server's value (`sprint/findings/saved-at-exposure.md`).
enum SyncBackfill {
    /// `local` plus each synced field it never read, from `remote`. `TopThree.unreadFieldsToCopy`
    /// decides which ones, by the stored contract, and the corpus pins it. The gate matters: an empty
    /// field means "never read" only on a build older than the field. Pulled under its contract, it's
    /// a real Return or un-pick that may not have pushed yet. `savedAt` also needs a row that can be
    /// Saved (S-WEB-02); the pick needs no such check, because a pick on a completed or Saved row is
    /// inert. The copy keeps `updatedAt` and every other field. Nil when nothing changes.
    static func fillingUnreadFields(of local: Task, from remote: Task, storedVersion: Int) -> Task? {
        let copy = TopThree.unreadFieldsToCopy(storedContract: storedVersion, local: row(local), remote: row(remote))
        var filled = local
        if copy.focus {
            filled.focusDate = remote.focusDate
            filled.focusRank = remote.focusRank
        }
        if copy.savedAt, SavedPlacement.canSave(local) { filled.savedAt = remote.savedAt }
        return filled == local ? nil : filled
    }

    private static func row(_ task: Task) -> TopThree.SyncRow {
        TopThree.SyncRow(updatedAt: task.updatedAt, focusDate: task.focusDate,
                         focusRank: task.focusRank, savedAt: task.savedAt)
    }
}
