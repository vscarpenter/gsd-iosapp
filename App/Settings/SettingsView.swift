import SwiftUI
import GSDModel
import GSDStore

/// The full Settings screen (design-spec §3 scope call): Appearance, Archive, Data &
/// Storage, About. Notifications + Cloud Sync are intentionally absent (Phase 4/5 — the
/// project ships no control that does nothing). `reshowOnboarding` flips the App-owned flag.
struct SettingsView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    /// Local mirror of the store's archive settings (UserDefaults-backed); writes flush back.
    @State private var archiveSettings: ArchiveSettings = .init()
    @State private var archiveStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                archiveSection
                DataStorageView()          // Group D sections
                aboutSection
            }
            .navigationTitle(String(localized: "Settings"))
            .toolbar { paletteButton(palette) }
            .onAppear { archiveSettings = store.archiveSettings }
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "Appearance")) {
            Picker(String(localized: "Theme"), selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in Text(theme.label).tag(theme.rawValue) }
            }
            Toggle(String(localized: "Show Completed Tasks"), isOn: $showCompleted)
        }
    }

    private var archiveSection: some View {
        Section(String(localized: "Archive")) {
            Toggle(String(localized: "Auto-archive completed tasks"), isOn: Binding(
                get: { archiveSettings.autoEnabled },
                set: { archiveSettings.autoEnabled = $0; store.archiveSettings = archiveSettings }
            ))
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
                    try? await store.runAutoArchiveSweep()
                    archiveStatus = String(localized: "Archive sweep complete.")
                }
            } label: {
                Label(String(localized: "Archive Now"), systemImage: "archivebox")
            }
            if let archiveStatus {
                Text(archiveStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        Section(String(localized: "About")) {
            LabeledContent(String(localized: "Version"), value: appVersion)
            Text(String(localized: "GSD stores all data locally on your device. Nothing is sent to a server."))
                .font(.footnote).foregroundStyle(.secondary)
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
