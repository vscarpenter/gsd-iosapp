import Foundation
import GSDModel
import GSDStore

/// Upgrades a share-created task's URL-derived title to the real page title, in the background.
/// Only acts when (1) the setting is on, (2) the task's title was derived from its shared URL
/// (so iOS's real titles, which differ, are skipped), and (3) the title is still that derived
/// value at save time (so a manual edit is never clobbered). Fire-and-forget: never blocks the
/// task appearing. App-layer glue — verified by build + on-device smoke; its logic reuses the
/// unit-tested URLTitle / PageTitleParser.
@MainActor
final class ShareTitleEnricher {
    private let store: TaskStore
    private let fetch: (URL) async -> String?

    init(store: TaskStore, fetch: @escaping (URL) async -> String?) {
        self.store = store
        self.fetch = fetch
    }

    func schedule(for task: GSDModel.Task) {
        guard AppGroupDefaults.shared.object(forKey: AppGroupDefaults.Key.fetchShareTitles) as? Bool ?? false,
              let url = sharedURL(in: task),
              task.title == derivedTitle(for: url) else { return }   // not URL-derived (incl. iOS) → skip
        _Concurrency.Task { [weak self] in
            guard let self,
                  let fetched = await self.fetch(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fetched.isEmpty,
                  var current = self.store.tasks.first(where: { $0.id == task.id }),
                  current.title == self.derivedTitle(for: url) else { return }   // edited meanwhile → skip
            current.title = String(fetched.prefix(FieldLimits.titleRange.upperBound))
            try? await self.store.save(current)
        }
    }

    /// The shared URL is the first line of the task's description (the share path stores it there).
    private func sharedURL(in task: GSDModel.Task) -> URL? {
        let firstLine = task.description.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? task.description
        guard let safe = URLSanitizer.sanitize(firstLine), let url = URL(string: safe) else { return nil }
        return url
    }

    /// The exact title the builder/extension produced from this URL, clamped identically.
    private func derivedTitle(for url: URL) -> String {
        String(URLTitle.derive(from: url.absoluteString).prefix(FieldLimits.titleRange.upperBound))
    }
}
