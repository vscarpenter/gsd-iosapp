import SwiftUI
import UIKit
import GSDStore
import GSDSync
import GSDSnapshot

@main
struct GSDApp: App {
    @State private var store: TaskStore
    @State private var session: SessionStore
    @State private var syncEngine: SyncEngine
    @State private var coordinator: SyncCoordinator
    @State private var widgetRefresher: WidgetSnapshotRefresher
    @State private var reminderResyncer: ReminderResyncer
    @State private var shareInbox: ShareInbox
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    init() {
        // Editorial chrome: serif nav titles + ink (not system-blue) bars. Must run before
        // any UINavigationBar/UITabBar is realized, so the App init is the right window.
        AppAppearance.configure()
        // The local store is the app's source of truth. An unopenable store (corruption,
        // failed migration) is moved aside — preserved as .corrupt — and recreated, instead
        // of crash-looping at launch. Only a second consecutive failure is unrecoverable.
        let database = try! AppDatabase.liveWithRecovery()
        // The live scheduler reads NotificationSettings straight from App-Group defaults
        // (the same suite the store persists to) — avoids a store-construction cycle.
        let scheduler = LiveReminderScheduler(settingsProvider: {
            TaskStore.readNotificationSettings(from: .shared)
        })
        // Repos shared by the store and the sync engine (Phase 5c): pulled writes reach the store's
        // observer, and the store's enqueues reach the engine's drain — same GRDB instances.
        let taskRepo = GRDBTaskRepository(database)
        let queueRepo = GRDBSyncQueueRepository(database)
        let historyRepo = GRDBSyncHistoryRepository(database)
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
            tokenProvider: { try await authService.validToken() },
            rawToken: { tokenStore.load() },   // health-only: lets an expired session say so
            history: historyRepo)
        _syncEngine = State(initialValue: syncEngine)
        // SyncCoordinator (Phase 5d) owns when sync fires (cadence/foreground/network/debounced push/SSE)
        // and the status surface; SessionStore delegates start/stop to it on sign-in/out.
        let realtime = PocketBaseRealtime(baseURL: AuthConfig.live.baseURL)
        let coordinator = SyncCoordinator(
            engine: syncEngine, realtime: realtime,
            tokenProvider: { try? await authService.validToken() },
            signedIn: { tokenStore.load() != nil })
        _coordinator = State(initialValue: coordinator)
        store.onMutation = { coordinator.scheduleDebouncedPush() }
        // Widget snapshot refresher (Phase 6a): rebuilds the App-Group snapshot + reloads
        // widget timelines whenever the task set changes (local edits, remote sync, background).
        let widgetRefresher = WidgetSnapshotRefresher(store: store)
        _widgetRefresher = State(initialValue: widgetRefresher)
        // Reminder resync (Fix A): remote writes (pull/SSE/reconcile) bypass the §9.1 mutation
        // hooks; this rebuilds reminders+badge from the snapshot on every observed change.
        let reminderResyncer = ReminderResyncer(store: store)
        _reminderResyncer = State(initialValue: reminderResyncer)
        store.onTasksChanged = {
            widgetRefresher.schedule()
            reminderResyncer.schedule()
        }
        // Share Extension inbox (Phase 6d): drains the App-Group outbox through the SAME
        // create() path on launch + foreground. Trivial glue; the logic is the tested ShareInbox.
        let shareInbox = ShareInbox(store: ShareOutboxStore())
        _shareInbox = State(initialValue: shareInbox)
        _session = State(initialValue: SessionStore(
            auth: authService, tokenStore: tokenStore, coordinator: coordinator,
            hasLocalActiveTasks: { !store.tasks.isEmpty },
            eraseLocal: { try await store.eraseAllData() }))
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
                .environment(coordinator)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme ?? nil)
                .tint(Surface.ink) // quiet graphite chrome; genuine actions opt into Surface.tint
                .task {
                    store.start()
                    await shareInbox.drain { try await store.create($0) }
                    widgetRefresher.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    coordinator.start(trigger: .launch)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        coordinator.enteredForeground()
                        _Concurrency.Task { await store.refreshBadge() }
                        _Concurrency.Task { await shareInbox.drain { try await store.create($0) } }
                    case .background:
                        coordinator.enteredBackground()
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presenting in if !presenting { hasOnboarded = true } }
                )) {
                    OnboardingView(
                        onFinish: { hasOnboarded = true },
                        onGoogleSignIn: {
                            hasOnboarded = true
                            _Concurrency.Task { await session.signIn(provider: "google") }
                        },
                        onAppleSignIn: {
                            hasOnboarded = true
                            _Concurrency.Task { await session.signIn(provider: "apple") }
                        }
                    )
                }
        }
    }
}
