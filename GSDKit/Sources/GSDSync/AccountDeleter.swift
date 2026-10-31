import Foundation
import GSDWire

/// Route-first account erasure with a bounded client-side fallback (B-08, App Store 5.1.1(v)).
/// Ports Android `AccountDeleter.kt` and web `lib/sync/pb-account-deletion.ts`.
///
/// `DELETE /api/gsd/account` erases tasks and the user in one server transaction. Production
/// (`api.vinny.io`) does not load that hook today, so a 404 is the expected live path and falls
/// back to erasing tasks client-side. ONLY a 404 falls back: any other route failure (offline,
/// 5xx, 401) stops with nothing changed. The user record is deleted only after a pass reports
/// an empty remote, so a retry after any failure is always safe.
public struct AccountDeleter: Sendable {
    /// What one remote task-erase pass found.
    public enum ErasePass: Equatable, Sendable {
        case empty                              // a complete listing came back empty
        case erased                             // deleted at least one task; re-list to confirm
        case partial                            // deleted at least one task, then failed
        case failed

        /// Classifies one `SyncEngine.eraseAllRemote` run. A signed-out user has nothing synced to erase.
        public init(_ result: SyncResult) {
            if result.notSignedIn {
                self = .empty
            } else if result.error != nil {
                self = result.pushed > 0 ? .partial : .failed
            } else if result.skipped {
                self = .failed
            } else {
                self = result.pushed == 0 ? .empty : .erased
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case deleted
        /// 401/403: the session is dead; sign in again before retrying.
        case sessionExpired
        /// Retryable. `remoteTasksErased` is true when the account survived but tasks were removed.
        case failed(remoteTasksErased: Bool)

        /// Whether the caller must sign out. Reconcile deletes a local task that is absent from the
        /// server with nothing queued, so once tasks have left the server, a live session would
        /// remove the local copies on its next sync, even after a relaunch.
        public var endsSession: Bool {
            switch self {
            case .deleted, .sessionExpired: true
            case .failed(let remoteTasksErased): remoteTasksErased
            }
        }
    }

    /// Enumerate-and-delete passes before the fallback refuses to touch the user record.
    static let maxPasses = 3

    private let deleteViaRoute: @Sendable () async throws -> Void
    private let erasePass: @Sendable () async -> ErasePass
    private let deleteUserRecord: @Sendable () async throws -> Void

    public init(deleteViaRoute: @escaping @Sendable () async throws -> Void,
                erasePass: @escaping @Sendable () async -> ErasePass,
                deleteUserRecord: @escaping @Sendable () async throws -> Void) {
        self.deleteViaRoute = deleteViaRoute
        self.erasePass = erasePass
        self.deleteUserRecord = deleteUserRecord
    }

    public func delete() async -> Outcome {
        do {
            try await deleteViaRoute()
            return .deleted
        } catch {
            guard Self.status(of: error) == 404 else { return Self.outcome(for: error, erased: false) }
        }
        var erased = false
        for _ in 0..<Self.maxPasses {
            switch await erasePass() {
            case .empty:
                do {
                    try await deleteUserRecord()
                    return .deleted
                } catch {
                    return Self.outcome(for: error, erased: erased)
                }
            case .erased:
                erased = true
            case .partial:
                return .failed(remoteTasksErased: true)
            case .failed:
                return .failed(remoteTasksErased: erased)
            }
        }
        return .failed(remoteTasksErased: erased)
    }

    private static func outcome(for error: Error, erased: Bool) -> Outcome {
        if case AuthError.notSignedIn = error { return .sessionExpired }
        let status = status(of: error)
        return status == 401 || status == 403 ? .sessionExpired : .failed(remoteTasksErased: erased)
    }

    private static func status(of error: Error) -> Int? {
        switch error {
        case PocketBaseError.http(let status, _), PocketBaseError.pocketBase(let status, _): status
        default: nil
        }
    }
}
