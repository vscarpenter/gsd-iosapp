import SwiftUI
import UIKit
import GSDStore
import GSDSync

@main
struct GSDApp: App {
    @State private var store: TaskStore
    @State private var session: SessionStore
    @State private var syncEngine: SyncEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        // The live scheduler reads NotificationSettings straight from App-Group defaults
        // (the same suite the store persists to) — avoids a store-construction cycle.
        let scheduler = LiveReminderScheduler(settingsProvider: {
            TaskStore.readNotificationSettings(from: .shared)
        })
        // Repos shared by the store and the sync engine (Phase 5c): pulled writes reach the store's
        // observer, and the store's enqueues reach the engine's drain — same GRDB instances.
        let taskRepo = GRDBTaskRepository(database)
        let queueRepo = GRDBSyncQueueRepository(database)
        let store = TaskStore(
            repository: taskRepo,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            reminders: scheduler,
            syncQueue: queueRepo
        )
        _store = State(initialValue: store)
        // Auth + transport (Phase 5b). Live seams; the pure AuthService logic is unit-tested.
        let tokenStore = KeychainTokenStore()
        let authService = AuthService(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            presenter: LiveWebAuthPresenter(),
            tokenStore: tokenStore,
            config: .live)
        // Sync engine (Phase 5c). Writes the shared repos directly; tokenProvider proxies to
        // AuthService.validToken (nil ⇒ no-op). deviceName read here on the main-actor init.
        let deviceName = UIDevice.current.name
        let syncEngine = SyncEngine(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            tasks: taskRepo, queue: queueRepo,
            cursor: SyncCursor(),
            deviceId: DeviceIdentity.current(nameProvider: { deviceName }).deviceId,
            tokenProvider: { try await authService.validToken() })
        _syncEngine = State(initialValue: syncEngine)
        _session = State(initialValue: SessionStore(auth: authService, tokenStore: tokenStore, syncEngine: syncEngine))
        // BGTaskScheduler handlers MUST be registered before the app finishes launching —
        // `init()` (pre-launch) is the correct window; a view's `.task` runs after launch
        // and would trip "all launch handlers must be registered before application finishes
        // launching". `App.init()` is main-actor-isolated, so the @MainActor register is safe.
        BackgroundRefresh.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(session)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme ?? nil)
                .task {
                    store.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    if session.isSignedIn { _ = await syncEngine.sync(trigger: .launch) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        _Concurrency.Task { await store.refreshBadge() }
                    case .background:
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presenting in if !presenting { hasOnboarded = true } }
                )) {
                    OnboardingView { hasOnboarded = true }
                }
        }
    }
}
