import AppIntents
import Foundation
import GSDModel
import GSDStore
import GSDSnapshot

enum GSDIntentStore {
    @MainActor
    static func makeStore() throws -> TaskStore {
        let database = try AppDatabase.liveWithRecovery()
        let queue = GRDBSyncQueueRepository(database)
        return TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            syncQueue: queue
        )
    }

    static func fetchTasks() async throws -> [Task] {
        let database = try AppDatabase.liveWithRecovery()
        return try await GRDBTaskRepository(database).fetchAll()
    }

    static func fetchTask(id: String) async throws -> Task? {
        let database = try AppDatabase.liveWithRecovery()
        return try await GRDBTaskRepository(database).fetch(id: id)
    }
}

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
    func entities(for identifiers: [GSDTaskEntity.ID]) async throws -> [GSDTaskEntity] {
        let ids = Set(identifiers)
        return try await GSDIntentStore.fetchTasks()
            .filter { ids.contains($0.id) }
            .map { GSDTaskEntity(task: $0) }
    }

    func suggestedEntities() async throws -> [GSDTaskEntity] {
        try await GSDIntentStore.fetchTasks()
            .filter { !$0.completed }
            .prefix(20)
            .map { GSDTaskEntity(task: $0) }
    }

    func entities(matching string: String) async throws -> [GSDTaskEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await GSDIntentStore.fetchTasks()
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

struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Task"
    static let description = IntentDescription("Create a task in GSD using capture shorthand like !, !!, *, and #tags.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var taskTitle: String

    @Parameter(title: "Quadrant", default: .doFirst)
    var quadrant: IntentQuadrant

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = CaptureParser.parse(taskTitle)
        let store = try await GSDIntentStore.makeStore()
        try await store.add(parsed, override: quadrant.quadrant)
        return .result(dialog: "Added \(parsed.title) to GSD.")
    }
}

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let description = IntentDescription("Mark a GSD task complete.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: GSDTaskEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let domainTask = try await GSDIntentStore.fetchTask(id: task.id) else {
            return .result(dialog: "That task is no longer available.")
        }
        if !domainTask.completed {
            let store = try await GSDIntentStore.makeStore()
            try await store.toggleComplete(domainTask)
        }
        return .result(dialog: "Completed \(domainTask.title).")
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
