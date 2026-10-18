import Foundation
import GSDModel

/// One direct `create` of a task against PocketBase, for a process that has no store and no
/// sync engine: the Share Extension after the user taps Save (spec §10.3). On iOS the extension
/// never foregrounds the app, so without this the capture waited in the outbox until the next
/// open or background refresh; with it, the task is on the server (and on every other device,
/// over SSE) before the sheet dismisses.
///
/// Deliberately narrow. It never refreshes a token (the app does that; an expired token is a
/// skip), never retries (the outbox is the retry), and never throws (the caller always writes the
/// outbox afterwards, with or without the record id). `owner` comes from the JWT and `device_id`
/// from the shared App-Group identity, exactly as `SyncEngine.push` stamps them, so a record pushed
/// here is indistinguishable from one the app pushed.
public struct DirectTaskPush: Sendable {
    public enum SkipReason: Equatable, Sendable {
        case signedOut          // no token in the shared keychain
        case tokenExpired       // the app will refresh it; the outbox path covers this capture
        case malformedToken     // no `id` claim → no owner to stamp (SyncEngine refuses this too)
        case noDeviceIdentity   // the app has never written `deviceId` to the App Group
    }
    public enum Outcome: Equatable, Sendable {
        case pushed(recordID: String)
        case skipped(SkipReason)
        case failed(String)     // network / HTTP / decode — description only, for a log line
    }

    private let client: PocketBaseClient
    private let token: @Sendable () -> String?
    private let deviceID: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - client: a `PocketBaseClient`; the extension passes one over a short-timeout session.
    ///   - token: the raw session JWT, or nil when signed out (`SharedTokenKeychain.load`).
    ///   - deviceID: the App-Group `deviceId`, or nil if the app has never set it.
    public init(client: PocketBaseClient,
                token: @escaping @Sendable () -> String?,
                deviceID: @escaping @Sendable () -> String?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.token = token
        self.deviceID = deviceID
        self.now = now
    }

    public func attempt(_ task: Task) async -> Outcome {
        guard let token = token() else { return .skipped(.signedOut) }
        guard !JWT.expiresWithin(0, of: token, now: now()) else { return .skipped(.tokenExpired) }
        guard let owner = JWT.userId(token) else { return .skipped(.malformedToken) }
        guard let deviceID = deviceID(), !deviceID.isEmpty else { return .skipped(.noDeviceIdentity) }
        let record = TaskWireMapper.toWire(task, owner: owner, deviceId: deviceID)
        do {
            return .pushed(recordID: try await client.createTask(record, token: token))
        } catch {
            return .failed(String("\(error)".prefix(200)))
        }
    }
}
