import Foundation

/// One page of a PocketBase list response (§7.4).
struct ListPage<T: Decodable>: Decodable {
    let page: Int
    let perPage: Int
    let totalItems: Int
    let totalPages: Int
    let items: [T]
}

extension PocketBaseClient {
    /// Pull `tasks` records with server-stamped `updated >= since` (PB space-form date), paging
    /// through ALL pages (data-completeness — never drop page 2+). `updated` is the PULL CURSOR
    /// only (§7.1 cursor exception, design 2026-06-10 Fix B) — LWW still resolves on
    /// `client_updated_at`. Malformed individual records are skipped (§7.4) via `Failable`.
    /// The `owner` API rule auto-scopes to the authed user. (Live gate: confirm the collection
    /// has the autodate `updated` field — owner confirmed 2026-06-10.)
    func listTasks(updatedSince since: String, token: String, perPage: Int = 200) async throws -> [PocketBaseTaskRecord] {
        var all: [PocketBaseTaskRecord] = []
        var page = 1
        while true {
            let filter = "updated >= \"\(since)\""
            let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
            let path = "/api/collections/tasks/records?page=\(page)&perPage=\(perPage)&sort=updated&filter=\(encoded)"
            let req = authedRequest(path: path, method: "GET", token: token)
            let pg = try await send(req, as: ListPage<Failable<PocketBaseTaskRecord>>.self)
            all.append(contentsOf: pg.items.compactMap(\.value))
            if page >= pg.totalPages { break }
            page += 1
        }
        return all
    }
}
