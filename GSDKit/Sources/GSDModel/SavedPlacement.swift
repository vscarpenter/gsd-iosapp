import Foundation

/// Which tasks may hold a Saved placement. One rule for every path that sets `savedAt`: the store's
/// Move to Saved and sync's backfill copy. Android `SavedPlacement.canSave`, web `saveTaskForLater`.
public enum SavedPlacement {
    public enum Refusal: Equatable, Sendable { case completed, timerRunning }

    /// Why `task` can't be Saved, or nil when it can.
    public static func refusal(for task: Task) -> Refusal? {
        if task.completed { return .completed }
        if TimeTracking.runningEntry(task.timeEntries) != nil { return .timerRunning }
        return nil
    }

    public static func canSave(_ task: Task) -> Bool { refusal(for: task) == nil }
}
