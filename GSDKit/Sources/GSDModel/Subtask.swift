/// A checklist item embedded in a Task (product spec §5.2). Max 50 per task.
public struct Subtask: Codable, Sendable, Identifiable, Equatable {
    public var id: String        // >= 4 chars
    public var title: String     // 1–100 chars
    public var completed: Bool

    public init(id: String, title: String, completed: Bool = false) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}
