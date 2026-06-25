import AppIntents
import SwiftUI
import UIKit
import GSDStore
import GSDSync
import GSDSnapshot

@main
struct GSDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TaskStore
    @State private var session: SessionStore
    @State private var syncEngine: SyncEngine
    @State private var coordinator: SyncCoordinator
    @State private var widgetRefresher: WidgetSnapshotRefresher
    @State private var reminderResyncer: ReminderResyncer
    @State private var spotlightIndexer: SpotlightIndexer
    @State private var shareInbox: ShareInbox
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false
    /// Frozen clock for the demo-video harness; `nil` in every normal launch.
    private let demoClock: Date?

    init() {
        // Editorial chrome: serif nav titles + ink (not system-blue) bars. Must run before
        // any UINavigationBar/UITabBar is realized, so the App init is the right window.
        AppAppearance.configure()
        // Demo-video harness: a fixed clock makes seeded data + relative dates deterministic
        // across takes. `nil` in normal launches, so production keeps the live system clock.
        let demoClock = DemoLaunch.clock
        self.demoClock = demoClock
        let now: @Sendable () -> Date = { demoClock ?? Date() }
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
        let taskRepo = GRDBTaskRepository(database, now: now)
        let queueRepo = GRDBSyncQueueRepository(database)
        let historyRepo = GRDBSyncHistoryRepository(database)
        let store = TaskStore(
            repository: taskRepo,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database, now: now),
            clock: now,
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
        let spotlightIndexer = SpotlightIndexer()
        _spotlightIndexer = State(initialValue: spotlightIndexer)
        store.onTasksChanged = {
            widgetRefresher.schedule()
            reminderResyncer.schedule()
            spotlightIndexer.schedule(tasks: store.tasks)
        }
        // Share Extension inbox (Phase 6d): drains the App-Group outbox through the SAME
        // create() path on launch + foreground. Trivial glue; the logic is the tested ShareInbox.
        let shareInbox = ShareInbox(store: ShareOutboxStore())
        _shareInbox = State(initialValue: shareInbox)
        _session = State(initialValue: SessionStore(
            auth: authService, tokenStore: tokenStore, coordinator: coordinator,
            hasLocalActiveTasks: { !store.tasks.isEmpty },
            eraseLocal: { try await store.eraseAllData() }))
        // In-app intents (Siri/Shortcuts run in this process) resolve the SAME store via
        // AppDependencyManager. A second connection on the live DB would be invisible to
        // this one's ValueObservation (stale UI/widgets/reminders) and racing the open
        // mid-write risks SQLITE_BUSY. Registered in init(): background intent launches
        // run App.init before any perform().
        AppDependencyManager.shared.add(dependency: store)
        // BGTaskScheduler handlers MUST be registered before the app finishes launching —
        // `init()` (pre-launch) is the correct window; a view's `.task` runs after launch
        // and would trip "all launch handlers must be registered before application finishes
        // launching". `App.init()` is main-actor-isolated, so the @MainActor register is safe.
        BackgroundRefresh.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            // Demo-only: the marketing-video choreography launches with --demo-home to record the
            // faux Home Screen widget beat. The app itself never passes it, so this stays unreachable.
            if ProcessInfo.processInfo.arguments.contains(DemoHomeScreen.launchArgument) {
                DemoHomeScreen()
            } else {
            ContentView()
                .environment(store)
                .environment(session)
                .environment(coordinator)
                .demoClock(demoClock)   // freezes relative-date rendering in the demo harness; no-op otherwise
                .preferredColorScheme(DemoLaunch.appearance ?? AppTheme(rawValue: themeRaw)?.colorScheme)
                .tint(Surface.ink) // quiet graphite chrome; genuine actions opt into Surface.tint
                .task {
                    store.start()
                    await DemoSeed.seedIfRequested(store, now: demoClock ?? .now)
                    await shareInbox.drain { try await store.create($0) }
                    // Drain the instant a share lands while the app is already running. On Mac
                    // Catalyst the extension never foregrounds the app and scenePhase `.active`
                    // is unreliable, so the launch/foreground drains alone leave captures stranded.
                    ShareOutboxSignal.observe {
                        _Concurrency.Task { await shareInbox.drain { try await store.create($0) } }
                    }
                    widgetRefresher.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    coordinator.start(trigger: .launch)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        AppDatabase.resume()   // restore writes before any foreground sync runs
                        coordinator.enteredForeground()
                        _Concurrency.Task { await store.refreshBadge() }
                        _Concurrency.Task { await shareInbox.drain { try await store.create($0) } }
                    case .background:
                        coordinator.enteredBackground()
                        BackgroundRefresh.schedule()
                        AppDatabase.suspend()  // release DB locks so iOS won't kill us (0xDEAD10CC)
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
        #if targetEnvironment(macCatalyst)
        .commands { GSDMenuCommands() }
        #endif
    }
}
