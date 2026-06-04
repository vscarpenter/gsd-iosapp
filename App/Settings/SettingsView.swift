import SwiftUI
import UserNotifications
import GSDModel
import GSDStore

/// The full Settings screen (design-spec §3 scope call): Appearance, Archive, Notifications,
/// Data & Storage, About. Cloud Sync is intentionally absent (Phase 5 — the project ships no
/// control that does nothing). `reshowOnboarding` flips the App-owned flag.
struct SettingsView: View {
    @Environment(TaskStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(SyncCoordinator.self) private var sync
    @Environment(PaletteController.self) private var palette
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    /// Local mirror of the store's archive settings (UserDefaults-backed); writes flush back.
    @State private var archiveSettings: ArchiveSettings = .init()
    @State private var archiveStatus: String?
    @State private var archiveStatusIsError = false

    @State private var notificationSettings: NotificationSettings = .init()
    /// OS authorization status, refreshed on appear (nil = not yet read).
    @State private var authStatusText: String?
    @State private var authIsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                accountSection
                archiveSection
                notificationSection
                DataStorageView()          // Group D sections
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .tint(Surface.tint)   // actions/links use the single calm tint, never system blue
            .navigationTitle(String(localized: "Settings"))
            .toolbar { paletteButton(palette) }
            .onAppear {
                archiveSettings = store.archiveSettings
                notificationSettings = store.notificationSettings
                refreshAuthStatus()
            }
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "Appearance")) {
            Picker(String(localized: "Theme"), selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in Text(theme.label).tag(theme.rawValue) }
            }
            Toggle(String(localized: "Show Completed Tasks"), isOn: $showCompleted)
                .tint(Surface.success)
        }
    }

    private var accountSection: some View {
        Section(String(localized: "Account")) {
            if session.isSignedIn {
                LabeledContent(String(localized: "Signed in"),
                               value: session.email ?? String(localized: "Account"))
                if let last = sync.lastSync, last.error == nil {
                    LabeledContent(String(localized: "Status"),
                                   value: String(localized: "Synced · \(sync.pendingCount) pending"))
                }
                if let msg = sync.health.message {
                    Text(msg).font(.footnote).foregroundStyle(Surface.ink3)
                }
                Button {
                    _Concurrency.Task { await session.syncNow() }
                } label: {
                    if sync.phase == .syncing {
                        ProgressView()
                    } else {
                        Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(sync.phase == .syncing)
                NavigationLink {
                    SyncHistoryView(engine: sync.engineForHistory)
                } label: {
                    Label(String(localized: "Sync History"), systemImage: "clock.arrow.circlepath")
                }
                Button(role: .destructive) {
                    session.signOut()
                } label: {
                    Label(String(localized: "Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    _Concurrency.Task { await session.signIn(provider: "google") }
                } label: {
                    if session.inProgress {
                        ProgressView()
                    } else {
                        Label(String(localized: "Sign in with Google"), systemImage: "person.crop.circle")
                    }
                }
                .disabled(session.inProgress)
            }
            if let error = session.lastError {
                Text(error).font(.footnote).foregroundStyle(Surface.alert)
            }
        }
    }

    private var archiveSection: some View {
        Section(String(localized: "Archive")) {
            Toggle(String(localized: "Auto-archive completed tasks"), isOn: Binding(
                get: { archiveSettings.autoEnabled },
                set: { archiveSettings.autoEnabled = $0; store.archiveSettings = archiveSettings }
            ))
            .tint(Surface.success)
            if archiveSettings.autoEnabled {
                Picker(String(localized: "Archive after"), selection: Binding(
                    get: { archiveSettings.afterDays },
                    set: { archiveSettings.afterDays = $0; store.archiveSettings = archiveSettings }
                )) {
                    ForEach(ArchiveSettings.allowedDays, id: \.self) { d in
                        Text(String(localized: "\(d) days")).tag(d)
                    }
                }
            }
            Button {
                _Concurrency.Task {
                    do {
                        try await store.runAutoArchiveSweep()
                        archiveStatus = String(localized: "Archive sweep complete.")
                        archiveStatusIsError = false
                    } catch {
                        archiveStatus = String(localized: "Couldn’t run auto-archive: \(error.localizedDescription)")
                        archiveStatusIsError = true
                    }
                }
            } label: {
                Label(String(localized: "Archive Now"), systemImage: "archivebox")
            }
            if let archiveStatus {
                Text(archiveStatus)
                    .font(.footnote)
                    .foregroundStyle(archiveStatusIsError ? Surface.alert : Surface.ink3)
            }
        }
    }

    private var notificationSection: some View {
        Section(String(localized: "Notifications")) {
            Toggle(String(localized: "Enable Reminders"), isOn: Binding(
                get: { notificationSettings.enabled },
                set: { notificationSettings.enabled = $0; flushNotificationSettings() }
            ))
            .tint(Surface.success)
            if notificationSettings.enabled {
                Picker(String(localized: "Default Reminder"), selection: Binding(
                    get: { notificationSettings.defaultReminder },
                    set: { notificationSettings.defaultReminder = $0; flushNotificationSettings() }
                )) {
                    ForEach(NotificationSettings.allowedReminders, id: \.self) { minutes in
                        Text(reminderLabel(minutes)).tag(minutes)
                    }
                }
                Toggle(String(localized: "Sound"), isOn: Binding(
                    get: { notificationSettings.soundEnabled },
                    set: { notificationSettings.soundEnabled = $0; flushNotificationSettings() }
                ))
                .tint(Surface.success)
                quietHoursControls
                authStatusRow
            }
        }
    }

    /// Quiet-hours start/end, each a toggle (nil ↔ a default time) + a `.hourAndMinute` picker.
    @ViewBuilder private var quietHoursControls: some View {
        Toggle(String(localized: "Quiet Hours"), isOn: Binding(
            get: { notificationSettings.quietHoursStart != nil && notificationSettings.quietHoursEnd != nil },
            set: { on in
                if on {
                    notificationSettings.quietHoursStart = notificationSettings.quietHoursStart ?? "22:00"
                    notificationSettings.quietHoursEnd = notificationSettings.quietHoursEnd ?? "07:00"
                } else {
                    notificationSettings.quietHoursStart = nil
                    notificationSettings.quietHoursEnd = nil
                }
                flushNotificationSettings()
            }
        ))
        .tint(Surface.success)
        if notificationSettings.quietHoursStart != nil {
            DatePicker(String(localized: "From"), selection: quietBinding(\.quietHoursStart, default: "22:00"),
                       displayedComponents: .hourAndMinute)
            DatePicker(String(localized: "To"), selection: quietBinding(\.quietHoursEnd, default: "07:00"),
                       displayedComponents: .hourAndMinute)
        }
    }

    /// The OS permission status + a contextual action (request when not-asked; open Settings when denied).
    @ViewBuilder private var authStatusRow: some View {
        if let authStatusText {
            LabeledContent(String(localized: "System Permission"), value: authStatusText)
        }
        if authIsDenied {
            Button(String(localized: "Open System Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } else if !store.notificationSettings.permissionAsked {
            Button(String(localized: "Enable Notifications")) {
                _Concurrency.Task { @MainActor in
                    _ = await store.requestNotificationAuthorization()
                    // Re-sync the local mirror so the store's stamped `permissionAsked`
                    // isn't overwritten by a later flushNotificationSettings() (e.g. a toggle).
                    notificationSettings = store.notificationSettings
                    refreshAuthStatus()
                }
            }
        }
    }

    /// Bind a `"HH:mm"` setting field to a `DatePicker` `Date` (today at that time, injected-tz-free
    /// since the picker shows local). Reading parses HH:mm → today's date; writing formats back.
    private func quietBinding(_ keyPath: WritableKeyPath<NotificationSettings, String?>,
                              default fallback: String) -> Binding<Date> {
        Binding(
            get: { Self.dateFrom(notificationSettings[keyPath: keyPath] ?? fallback) },
            set: { notificationSettings[keyPath: keyPath] = Self.hhmm(from: $0); flushNotificationSettings() }
        )
    }

    private func flushNotificationSettings() { store.notificationSettings = notificationSettings }

    private func refreshAuthStatus() {
        _Concurrency.Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authStatusText = String(localized: "Allowed"); authIsDenied = false
            case .denied:
                authStatusText = String(localized: "Denied"); authIsDenied = true
            case .notDetermined:
                authStatusText = String(localized: "Not requested"); authIsDenied = false
            @unknown default:
                authStatusText = nil; authIsDenied = false
            }
        }
    }

    private func reminderLabel(_ minutes: Int) -> String {
        switch minutes {
        case 15:   String(localized: "15 minutes before")
        case 30:   String(localized: "30 minutes before")
        case 60:   String(localized: "1 hour before")
        case 120:  String(localized: "2 hours before")
        case 1440: String(localized: "1 day before")
        default:   String(localized: "\(minutes) minutes before")
        }
    }

    /// Parse `"HH:mm"` → a Date at that time today (local). Malformed → start of today.
    private static func dateFrom(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":")
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        comps.hour = parts.count == 2 ? Int(parts[0]) : 0
        comps.minute = parts.count == 2 ? Int(parts[1]) : 0
        return Calendar.current.date(from: comps) ?? .now
    }
    /// Format a Date → `"HH:mm"` (local, zero-padded).
    private static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private var aboutSection: some View {
        Section(String(localized: "About")) {
            LabeledContent(String(localized: "Version"), value: appVersion)
            Text(String(localized: "GSD stores your data locally on your device. When you sign in, your tasks sync with your account; signed out, nothing leaves your device."))
                .font(.footnote).foregroundStyle(Surface.ink3)
            Link(String(localized: "Privacy Policy"), destination: URL(string: "https://vinny.dev/gsd/privacy")!)
            Button {
                hasOnboarded = false       // App root re-presents onboarding on the flag change
            } label: {
                Label(String(localized: "Show Onboarding Again"), systemImage: "sparkles")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
