import AppIntents
import Foundation
import GSDModel
import GSDStore
import GSDSnapshot
import UIKit

// Intents run in the app's process and resolve the ONE app-wired TaskStore via
// @Dependency (registered in GSDApp.init). Opening a second database connection here
// would bypass the app's ValueObservation (writes invisible to the UI/widgets/sync
// hooks), skip the LiveReminderScheduler, and contend with the app's open writer.

enum IntentQuadrant: String, AppEnum {
    case doFirst
    case schedule
    case delegate
    case eliminate

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quadrant")
    static let caseDisplayRepresentations: [IntentQuadrant: DisplayRepresentation] = [
        .doFirst: "Do First",
        .schedule: "Schedule",
        .delegate: "Delegate",
        .eliminate: "Eliminate",
    ]

    var quadrant: Quadrant {
        switch self {
        case .doFirst: .urgentImportant
        case .schedule: .notUrgentImportant
        case .delegate: .urgentNotImportant
        case .eliminate: .notUrgentNotImportant
        }
    }
}

enum GSDDestination: String, AppEnum {
    case matrix
    case capture
    case todayFocus
    case thisWeek
    case overdue
    case dashboard
    case settings

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Destination")
    static let caseDisplayRepresentations: [GSDDestination: DisplayRepresentation] = [
        .matrix: "Matrix",
        .capture: "New Task",
        .todayFocus: "Today's Focus",
        .thisWeek: "This Week",
        .overdue: "Overdue",
        .dashboard: "Dashboard",
        .settings: "Settings",
    ]

    var route: DeepLinkRoute {
        switch self {
        case .matrix: .focus
        case .capture: .capture
        case .todayFocus: .smartView("today-focus")
        case .thisWeek: .smartView("this-week")
        case .overdue: .smartView("overdue")
        case .dashboard: .dashboard
        case .settings: .settings
        }
    }
}

struct GSDTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = GSDTaskQuery()

    let id: String
    let title: String
    let completed: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: completed ? "Completed" : "Active"
        )
    }
}

struct GSDTaskQuery: EntityQuery, EntityStringQuery {
    @Dependency private var store: TaskStore

    func entities(for identifiers: [GSDTaskEntity.ID]) async throws -> [GSDTaskEntity] {
        var found: [GSDTaskEntity] = []
        for id in identifiers {
            if let task = try await store.fetchTask(id: id) {
                found.append(GSDTaskEntity(task: task))
            }
        }
        return found
    }

    func suggestedEntities() async throws -> [GSDTaskEntity] {
        try await store.fetchAllTasks()
            .filter { !$0.completed }
            .prefix(20)
            .map { GSDTaskEntity(task: $0) }
    }

    func entities(matching string: String) async throws -> [GSDTaskEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await store.fetchAllTasks()
            .filter { task in
                query.isEmpty
                || task.title.lowercased().contains(query)
                || task.tags.contains { $0.lowercased().contains(query) }
            }
            .prefix(20)
            .map { GSDTaskEntity(task: $0) }
    }
}

extension GSDTaskEntity {
    init(task: Task) {
        id = task.id
        title = task.title
        completed = task.completed
    }
}

/// Siri/Shortcuts intents run in the background, where the database is suspended as the
/// `0xDEAD10CC` mitigation (see `AppDatabase`). A `DatabaseQueue` rejects BOTH reads and writes
/// while suspended ("Database is suspended" / `SQLITE_ABORT` on `BEGIN IMMEDIATE`), so any intent
/// that touches the store must resume it for its work window — then restore the prior state,
/// exactly as `BackgroundRefresh` does for BG refresh. Foreground runs (`applicationState ==
/// .active`) are already resumed; re-suspending one would wrongly lock out the live UI, so gate on it.
@MainActor
private func withDatabaseResumedForIntent<R>(_ body: () async throws -> R) async throws -> R {
    let wasSuspended = UIApplication.shared.applicationState != .active
    if wasSuspended { AppDatabase.resume() }
    defer { if wasSuspended { AppDatabase.suspend() } }
    return try await body()
}

struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Task"
    static let description = IntentDescription("Create a task in GSD using capture shorthand like !, !!, *, and #tags.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var taskTitle: String

    /// Optional on purpose: nil lets the capture shorthand (!, !!, *) place the task —
    /// a non-nil default here would silently discard the very shorthand we advertise.
    @Parameter(title: "Quadrant")
    var quadrant: IntentQuadrant?

    @Dependency private var store: TaskStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = CaptureParser.parse(taskTitle)
        try await withDatabaseResumedForIntent {
            try await store.add(parsed, override: quadrant?.quadrant)
        }
        return .result(dialog: "Added \(parsed.title) to GSD.")
    }
}

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let description = IntentDescription("Mark a GSD task complete.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: GSDTaskEntity

    @Dependency private var store: TaskStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await withDatabaseResumedForIntent { () -> String in
            guard let domainTask = try await store.fetchTask(id: task.id) else {
                return "That task is no longer available."
            }
            if !domainTask.completed {
                try await store.toggleComplete(domainTask)
            }
            return "Completed \(domainTask.title)."
        }
        return .result(dialog: "\(message)")
    }
}

struct OpenGSDIntent: AppIntent {
    static let title: LocalizedStringResource = "Open GSD"
    static let description = IntentDescription("Open GSD to a useful task destination.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination", default: .todayFocus)
    var destination: GSDDestination

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DeepLinkHandoff.open(destination.route)
        return .result(dialog: "Opening GSD.")
    }
}

struct GSDShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a task in \(.applicationName)",
            ],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "Complete a task in \(.applicationName)",
                "Mark a task done in \(.applicationName)",
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: OpenGSDIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show my focus in \(.applicationName)",
            ],
            shortTitle: "Open GSD",
            systemImageName: "target"
        )
    }
}
