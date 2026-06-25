import UIKit
import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDSnapshot

/// The share-extension entry point (NSExtensionPrincipalClass). Extracts the shared URL or text
/// from the NSItemProvider, then hosts the SwiftUI compose sheet. GRDB-free: it only writes a
/// SharedCapture to the App-Group outbox; the app materializes it later (spec §4.2).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let outbox = ShareOutboxStore()

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
            save: { [weak self] capture in try self?.outbox.write(capture) },
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
