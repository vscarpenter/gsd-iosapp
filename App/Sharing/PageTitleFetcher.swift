import Foundation
import GSDModel

/// Fetches a web page's title for shared-link enrichment. Thin `URLSession` glue over the
/// pure `PageTitleParser`; reads at most ~64 KB (enough for `<head>`), times out at 8s, and
/// returns nil on any failure (offline, non-2xx, plain-http blocked by ATS, no title) so the
/// caller keeps the offline-derived title. App-layer I/O — verified by build + on-device smoke.
struct PageTitleFetcher {
    private let maxBytes = 64 * 1024

    func title(for url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(maxBytes)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        return html.flatMap(PageTitleParser.parse)
    }
}
