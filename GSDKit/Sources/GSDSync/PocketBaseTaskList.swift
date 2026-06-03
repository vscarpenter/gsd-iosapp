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
    /// Pull `tasks` records with `client_updated_at >= since` (ISO), paging through ALL pages
    /// (data-completeness — never drop page 2+). Malformed individual records are skipped (§7.4) via
    /// `Failable`. The `owner` API rule auto-scopes to the authed user. (Confirm the filter syntax at
    /// the live gate.)
    func listTasks(updatedSince since: String, token: String, perPage: Int = 200) async throws -> [PocketBaseTaskRecord] {
        var all: [PocketBaseTaskRecord] = []
        var page = 1
        while true {
            let filter = "client_updated_at >= \"\(since)\""
            let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
            let path = "/api/collections/tasks/records?page=\(page)&perPage=\(perPage)&sort=client_updated_at&filter=\(encoded)"
            let req = authedRequest(path: path, method: "GET", token: token)
            let pg = try await send(req, as: ListPage<Failable<PocketBaseTaskRecord>>.self)
            all.append(contentsOf: pg.items.compactMap(\.value))
            if page >= pg.totalPages { break }
            page += 1
        }
        return all
    }
}
