import UIKit
import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDSnapshot
import GSDWire

/// The share-extension entry point (NSExtensionPrincipalClass). Extracts the shared URL or text
/// from the NSItemProvider, then hosts the SwiftUI compose sheet. GRDB-free. On Add it pushes
/// the task straight to PocketBase when it can (signed in, online, a few seconds' budget) and
/// then writes the SharedCapture to the App-Group outbox either way; the app lands it on its next
/// drain — without a second push when the record id is already there (spec §10.3).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let outbox = ShareOutboxStore()
    /// The extension's whole lifetime after Add is a few seconds, so the push gets a hard budget:
    /// a slow or absent network falls through to the outbox rather than a hung sheet.
    private let push = DirectTaskPush(
        client: PocketBaseClient(baseURL: PocketBaseEndpoint.liveBaseURL, session: ShareViewController.shortBudgetSession()),
        token: { SharedTokenKeychain.load() },
        deviceID: { UserDefaults(suiteName: AppGroup.id)?.string(forKey: AppGroup.deviceIDKey) })

    private static func shortBudgetSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false       // offline → fail now, take the outbox path
        return URLSession(configuration: config)
    }

    /// Choose the task id here so both outcomes share it: pushed → the app lands the same task
    /// without re-pushing; not pushed (or timed out but landed) → the app's queued create resolves
    /// to an update of the server copy, never a duplicate.
    private func saveAndPush(_ capture: SharedCapture) async throws {
        var capture = capture
        capture.taskID = IDGenerator.generate(size: IDGenerator.Size.task)
        if let task = capture.pushedTask(), case .pushed(let recordID) = await push.attempt(task) {
            capture.remoteRecordID = recordID
        }
        try outbox.write(capture)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let (title, urls) = await self.extractSharedItem()
            self.presentCompose(prefilledTitle: title, urls: urls)
        }
    }

    /// Prefer a web-URL attachment; fall back to plain text; else present empty (user types).
    /// Uses `loadObject(ofClass:)` (typed, Sendable values) so no non-Sendable payload or
    /// completion closure crosses the concurrency boundary (Swift 6 strict concurrency).
    private func extractSharedItem() async -> (String, [String]) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else {
            return ("", [])
        }
        let pageTitle = item.attributedContentText?.string ?? ""

        if let urlProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            let urlString = await loadObject(URL.self, from: urlProvider)?.absoluteString ?? ""
            // No page title (e.g. macOS Safari only provides the URL) → derive a readable one
            // so the compose sheet shows it too, not just the materialized task.
            let title = pageTitle.isEmpty ? URLTitle.derive(from: urlString) : pageTitle
            return (title, urlString.isEmpty ? [] : [urlString])
        } else if let textProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            let text = await loadObject(String.self, from: textProvider) ?? ""
            return (text, [])
        } else {
            return (pageTitle, [])
        }
    }

    /// Bridges `NSItemProvider.loadObject` to async; `T` (URL/String) is Sendable, so nothing
    /// unsafe escapes the background completion handler.
    private func loadObject<T>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T: _ObjectiveCBridgeable & Sendable, T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    private func presentCompose(prefilledTitle: String, urls: [String]) {
        let composeView = ShareComposeView(
            initialTitle: prefilledTitle,
            urls: urls,
            save: { [weak self] capture in try await self?.saveAndPush(capture) },
            onComplete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "dev.vinny.gsd.share", code: 0))
            }
        )
        let host = UIHostingController(rootView: composeView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
