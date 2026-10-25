import Foundation
import GSDModel

/// The fixtures the screenshot and video harness seeds through `--demo-seed`: 24 tasks across the
/// four quadrants, 14 of them completed over the two weeks before `now`, so the dashboard trend
/// reads like real history. They live in the package so the seed's one safety rule is testable.
///
/// The rule: `seed` fills an empty store and refuses any other. On 2026-10-24 the Mac widths
/// harness ran the seed against the owner's real store. A dev-signed Catalyst build shares the
/// App Group container and the keychain session with the installed app, so the seed trashed 166
/// real tasks and pushed their deletes to PocketBase. The seed has no delete path any more, and
/// the App adds the outer fence: a harness launch (`HarnessLaunch`) opens an in-memory database,
/// runs signed out, and points every shared seam at scratch, so even a seed that passes this
/// check cannot reach the server or the real app.
public enum DemoFixtures {
    public enum SeedError: Error, Equatable {
        /// The store holds at least one task, fixture or real. Nothing was changed.
        case storeNotEmpty
    }

    /// Every fixture id, for tests that check a seeded store.
    public static let ids: Set<String> = Set(tasks(now: Date(timeIntervalSince1970: 0)).map(\.id))

    /// Fill an empty store. Every harness launch opens a fresh in-memory store, so a non-empty one
    /// means the seed is somewhere it must not be, and it is refused untouched.
    @MainActor
    public static func seed(into store: TaskStore, now: Date) async throws {
        guard try await store.fetchAllTasks().isEmpty else { throw SeedError.storeNotEmpty }
        for task in tasks(now: now) {
            try await store.create(task)
            // create() stamps createdAt with "now"; save() keeps the task's own. The second
            // write backdates the seeded creation so the dashboard's Created trend reads like
            // real history instead of one spike on the demo day.
            if task.createdAt < now { try await store.save(task) }
        }
    }

    public static func tasks(now: Date) -> [Task] {
        let cal = Calendar.current
        func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }
        func daysFromNow(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: now)! }

        // urgent/important → quadrant: (T,T) Do First · (F,T) Schedule · (T,F) Delegate · (F,F) Eliminate
        // `created` is days ago, so the dashboard's Created trend spreads across the past two weeks.
        func t(_ id: String, _ title: String, u: Bool, i: Bool,
               tags: [String] = [], recurrence: RecurrenceType = .none,
               subtasks: [Subtask] = [], deps: [String] = [],
               due: Date? = nil, done: Date? = nil, created: Int = 0) -> Task {
            Task(id: id, title: title, urgent: u, important: i,
                 completed: done != nil, completedAt: done,
                 createdAt: daysAgo(created), updatedAt: now, dueDate: due,
                 recurrence: recurrence, tags: tags, subtasks: subtasks, dependencies: deps)
        }

        var out: [Task] = []
        // ---- Active: Do First ---- (varied due dates so the cards read realistically AND
        // deterministically against the frozen demo clock: today / +2d / overdue)
        out.append(t("demo-finance", "Get finance sign-off", u: true, i: true, tags: ["work"],
                     due: cal.startOfDay(for: now), created: 1))
        out.append(t("demo-deck", "Finish the Q3 board deck", u: true, i: true, tags: ["work"],
                     subtasks: [Subtask(id: "sub1", title: "Pull revenue numbers", completed: true),
                                Subtask(id: "sub2", title: "Draft the narrative"),
                                Subtask(id: "sub3", title: "Design the key slides")],
                     deps: ["demo-finance"], due: daysFromNow(2), created: 3))
        // Overdue, and kept free of subtasks/deps so it's the clean card we complete on camera.
        out.append(t("demo-investor", "Reply to the investor email", u: true, i: true, tags: ["work"],
                     due: daysAgo(1), created: 2))
        // ---- Active: Schedule ----
        out.append(t("demo-vacation", "Plan the summer vacation", u: false, i: true, tags: ["family"],
                     due: daysFromNow(7), created: 5))
        out.append(t("demo-physical", "Book the annual physical", u: false, i: true, tags: ["health"],
                     created: 9))
        out.append(t("demo-passport", "Renew passport", u: false, i: true, tags: ["family"],
                     due: daysFromNow(30), created: 4))
        // ---- Active: Delegate ----
        out.append(t("demo-newsletter", "Send the weekly newsletter", u: true, i: false,
                     tags: ["work"], recurrence: .weekly, due: daysFromNow(1), created: 6))
        out.append(t("demo-supplies", "Order office supplies", u: true, i: false, tags: ["errands"],
                     created: 1))
        // ---- Active: Eliminate ----
        out.append(t("demo-downloads", "Sort the downloads folder", u: false, i: false, tags: ["errands"],
                     created: 8))
        out.append(t("demo-reviews", "Browse gadget reviews", u: false, i: false, created: 12))

        // ---- Completed history (drives the Dashboard trend; completedAt is preserved by create()) ----
        let done: [(String, String, Bool, Bool, [String], Int)] = [
            ("d-expense", "Submit the expense report", true, true, ["work"], 1),
            ("d-standup", "Write standup notes", true, false, ["work"], 1),
            ("d-dentist", "Call the dentist", false, true, ["health"], 2),
            ("d-pr", "Review PR #482", true, true, ["work"], 2),
            ("d-water", "Water the plants", false, false, ["home"], 3),
            ("d-card", "Pay the credit card", false, true, ["errands"], 3),
            ("d-grocery", "Grocery run", true, false, ["errands"], 4),
            ("d-login", "Fix the login bug", true, true, ["work"], 5),
            ("d-walk", "Walk the dog", true, false, ["home"], 5),
            ("d-recipe", "Try the new recipe", false, false, ["home"], 6),
            ("d-invoice", "Send the client invoice", true, true, ["work"], 7),
            ("d-1on1", "Prep the 1:1 agenda", false, true, ["work"], 8),
            ("d-laundry", "Do the laundry", true, false, ["home"], 9),
            ("d-read", "Read the design article", false, false, [], 11),
        ]
        for (id, title, u, i, tags, ago) in done {
            out.append(t(id, title, u: u, i: i, tags: tags, done: daysAgo(ago), created: ago + 1 + ago % 3))
        }
        return out
    }
}
