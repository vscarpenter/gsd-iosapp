import Foundation

/// One page of a PocketBase list response (§7.4).
struct ListPage<T: Decodable>: Decodable {
    let page: Int
    let perPage: Int
    let totalItems: Int
    let totalPages: Int
    let items: [T]
}

/// A remote listing that can't be trusted end to end (parity S10): more records than the cap,
/// pages out of order, a total that moved mid-listing, or fewer records than the server promised.
/// Nothing destructive may act on it, so push, reconcile, and erase stop and report it.
package struct RemoteListingIncomplete: Error, Equatable, CustomStringConvertible {
    package let reason: String
    package var description: String { "Remote task listing incomplete: \(reason)" }
}

/// The records one listing decoded, plus a count of the ones it couldn't.
struct RemoteListing<T: Sendable>: Sendable {
    var items: [T] = []
    var undecodable = 0
}

/// A listed record's join key, so a listing can refuse the same task twice (parity S10).
protocol RemoteTaskKeyed {
    var taskId: String { get }
}

extension PocketBaseTaskRecord: RemoteTaskKeyed {}
extension RemoteTaskIdentity: RemoteTaskKeyed {}

extension PocketBaseClient {
    /// The most remote tasks one account may hold. Web and Android use the same cap (parity S10).
    static let maxRemoteTasks = 10_000

    /// Pull `tasks` records with server-stamped `updated >= since` (PB space-form date), paging
    /// through ALL pages (data-completeness — never drop page 2+). `updated` is the PULL CURSOR
    /// only (§7.1 cursor exception, design 2026-06-10 Fix B) — LWW still resolves on
    /// `client_updated_at`. Malformed individual records are skipped (§7.4): pull only adds and
    /// updates, so a record it can't read waits for a later pull. A listing whose pages don't
    /// add up still throws. The `owner` API rule auto-scopes to the authed user. (Live gate:
    /// confirm the collection has the autodate `updated` field — owner confirmed 2026-06-10.)
    package func listTasks(updatedSince since: String, token: String, perPage: Int = 200) async throws -> [PocketBaseTaskRecord] {
        try await listAll(PocketBaseTaskRecord.self, updatedSince: since, token: token, perPage: perPage).items
    }

    /// Walk every page and return all of it, or throw `RemoteListingIncomplete`. A record that
    /// fails to decode still counts toward the server's `totalItems`, and the caller decides what
    /// it means: pull skips it, while the push and reconcile index refuses to go on. The same
    /// task listed twice throws: under `sort=updated`, a record edited mid-listing moves to the
    /// end, and the record it displaced is skipped while the counts still match.
    func listAll<T: Decodable & Sendable & RemoteTaskKeyed>(_ type: T.Type, updatedSince since: String,
                                                            token: String, perPage: Int = 200) async throws -> RemoteListing<T> {
        var listing = RemoteListing<T>()
        var seen = Set<String>()
        var listed = 0
        var total: Int?
        var page = 1
        while true {
            let pg = try await fetchPage(T.self, page: page, updatedSince: since, token: token, perPage: perPage)
            try Self.validate(pg, page: page, total: total, listedSoFar: listed)
            total = pg.totalItems
            listed += pg.items.count
            let decoded = pg.items.compactMap(\.value)
            for record in decoded where !seen.insert(record.taskId).inserted {
                throw RemoteListingIncomplete(reason: "task \(record.taskId) was listed twice")
            }
            listing.items += decoded
            listing.undecodable += pg.items.count - decoded.count
            if page >= pg.totalPages { break }
            page += 1
        }
        guard listed == total else {
            throw RemoteListingIncomplete(reason: "listed \(listed) of \(total ?? 0) records")
        }
        return listing
    }

    private func fetchPage<T: Decodable>(_ type: T.Type, page: Int, updatedSince since: String,
                                         token: String, perPage: Int) async throws -> ListPage<Failable<T>> {
        let filter = "updated >= \"\(since)\""
        let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let path = "/api/collections/tasks/records?page=\(page)&perPage=\(perPage)&sort=updated&filter=\(encoded)"
        return try await send(authedRequest(path: path, method: "GET", token: token), as: ListPage<Failable<T>>.self)
    }

    /// The page checks web (`fetchBoundedRemoteTasks`) and Android (`BoundedListing`) run.
    private static func validate<T: Decodable>(_ pg: ListPage<Failable<T>>, page: Int, total: Int?,
                                               listedSoFar: Int) throws {
        if pg.page != page {
            throw RemoteListingIncomplete(reason: "expected page \(page), got page \(pg.page)")
        }
        if pg.totalItems > maxRemoteTasks || listedSoFar + pg.items.count > maxRemoteTasks {
            throw RemoteListingIncomplete(reason: "more than \(maxRemoteTasks) records")
        }
        if let total, pg.totalItems != total {
            throw RemoteListingIncomplete(reason: "the total changed from \(total) to \(pg.totalItems) mid-listing")
        }
        if pg.items.isEmpty && page < pg.totalPages {
            throw RemoteListingIncomplete(reason: "page \(page) was empty before the last page")
        }
    }
}
