@preconcurrency import CoreSpotlight
import Foundation
import GSDModel
import GSDSnapshot
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexer {
    private let index: CSSearchableIndex
    private var task: _Concurrency.Task<Void, Never>?

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    func schedule(tasks: [Task]) {
        task?.cancel()
        task = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: .seconds(1))
            if _Concurrency.Task.isCancelled { return }
            await Self.index(tasks: tasks, in: self.index)
        }
    }

    private static func index(tasks: [Task], in index: CSSearchableIndex) async {
        let activeItems = tasks.filter { !$0.completed }.map(searchableItem)
        await withCheckedContinuation { continuation in
            index.deleteSearchableItems(withDomainIdentifiers: ["dev.vinny.gsd.tasks"]) { _ in
                index.indexSearchableItems(activeItems) { _ in continuation.resume() }
            }
        }
    }

    private static func searchableItem(for task: Task) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = task.title
        attributes.contentDescription = task.description.isEmpty ? task.quadrant.title : task.description
        attributes.keywords = task.tags + [task.quadrant.title, "GSD"]
        // No relatedUniqueIdentifier: it links an item to a separately indexed
        // NSUserActivity (none here) — a dangling value misuses the field.
        let item = CSSearchableItem(
            uniqueIdentifier: task.id,
            domainIdentifier: "dev.vinny.gsd.tasks",
            attributeSet: attributes
        )
        // The property is null_resettable: nil RESETS to the ~30-day default TTL.
        // distantFuture is the "keep until we delete it" idiom.
        item.expirationDate = .distantFuture
        return item
    }
}
