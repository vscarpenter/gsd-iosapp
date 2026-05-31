import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDStore

/// Data & Storage settings: export (ShareLink), import (.fileImporter → Replace/Merge),
/// and Erase All (type-RESET + export-first prompt). Rendered as `Form` sections so it can
/// be embedded in `SettingsView` or shown standalone. All actions go through the store.
struct DataStorageView: View {
    @Environment(TaskStore.self) private var store

    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var showModePicker = false
    @State private var showEraseAlert = false
    @State private var resetConfirmText = ""
    @State private var statusMessage: String?

    var body: some View {
        Group {
            Section(String(localized: "Export")) {
                if let exportURL {
                    ShareLink(item: exportURL, preview: SharePreview(String(localized: "GSD Tasks"))) {
                        Label(String(localized: "Share Export File"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    exportURL = makeExportURL()
                } label: {
                    Label(String(localized: "Prepare Export"), systemImage: "doc.badge.arrow.up")
                }
            }

            Section(String(localized: "Import")) {
                Button {
                    showImporter = true
                } label: {
                    Label(String(localized: "Import Tasks…"), systemImage: "square.and.arrow.down")
                }
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    resetConfirmText = ""
                    showEraseAlert = true
                } label: {
                    Label(String(localized: "Erase All Data"), systemImage: "trash")
                }
            } footer: {
                Text(String(localized: "Erasing removes all tasks, archived items, and custom views. Your appearance settings are kept. Export first if you want a backup."))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImportPick(result)
        }
        .confirmationDialog(String(localized: "Import Mode"), isPresented: $showModePicker, titleVisibility: .visible) {
            Button(String(localized: "Merge (keep existing)")) { runImport(mode: .merge) }
            Button(String(localized: "Replace (erase existing)"), role: .destructive) { runImport(mode: .replace) }
            Button(String(localized: "Cancel"), role: .cancel) { pendingImportData = nil }
        } message: {
            Text(String(localized: "Merge keeps your current tasks and adds the imported ones. Replace deletes your current tasks first."))
        }
        .alert(String(localized: "Erase All Data"), isPresented: $showEraseAlert) {
            TextField(String(localized: "Type RESET to confirm"), text: $resetConfirmText)
            Button(String(localized: "Erase"), role: .destructive) {
                guard resetConfirmText == "RESET" else { return }
                _Concurrency.Task {
                    try? await store.eraseAllData()
                    statusMessage = String(localized: "All data erased.")
                }
            }
            .disabled(resetConfirmText != "RESET")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This cannot be undone. Type RESET to confirm. Consider exporting first."))
        }
    }

    /// Write the export JSON to a temp `.json` file so `ShareLink(item: URL)` (URL is
    /// `Transferable`, FileDocument is not) can share it with a real filename.
    private func makeExportURL() -> URL? {
        guard let data = try? store.exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GSD-Tasks.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            statusMessage = String(localized: "Couldn’t prepare the export file.")
            return nil
        }
    }

    private func handleImportPick(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        // Security-scoped resource: a file picked outside the sandbox must be opened
        // within a start/stop access pair.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            statusMessage = String(localized: "Couldn’t read that file."); return
        }
        pendingImportData = data
        showModePicker = true
    }

    private func runImport(mode: TaskStore.ImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        _Concurrency.Task {
            do {
                let result = try await store.importTasks(data, mode: mode)
                statusMessage = result.skipped == 0
                    ? String(localized: "Imported \(result.tasks.count) tasks.")
                    : String(localized: "Imported \(result.tasks.count) tasks (\(result.skipped) skipped).")
            } catch {
                statusMessage = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }
}
