import SwiftUI
import GSDStore

@main
struct GSDApp: App {
    @State private var store: TaskStore
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue

    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        _store = State(initialValue: TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database)
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme ?? nil)
                .task { store.start() }
        }
    }
}
