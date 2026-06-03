import Foundation

/// Minimal PocketBase realtime (SSE) client over `URLSession.bytes` (§7.6). Foundation-only.
/// Protocol (connect CONFIRMED at Probe P1, 2026-06-03; subscribe/envelope verify at the A74 gate):
/// `GET /api/realtime` streams a `PB_CONNECT` event whose data is `{"clientId":"…"}`;
/// `POST /api/realtime {clientId, subscriptions:["tasks"]}` with `Authorization` subscribes;
/// subsequent events (named `tasks`) carry `{"action","record"}` in their `data`.
public final class PocketBaseRealtime: Sendable {
    private let baseURL: String
    private let session: URLSession

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Yields the `data` JSON string of each `tasks` event. Throws on connect/subscribe failure (the
    /// coordinator catches + retries with backoff). Cancelling the consuming task disconnects.
    public func events(token: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = _Concurrency.Task { [baseURL, session] in
                do {
                    var req = URLRequest(url: URL(string: baseURL + "/api/realtime")!)
                    req.timeoutInterval = .infinity
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw PocketBaseError.network("realtime connect failed")
                    }
                    var parser = SSEParser()
                    var subscribed = false
                    for try await line in bytes.lines {
                        if _Concurrency.Task.isCancelled { break }
                        guard let event = parser.feed(line) else { continue }
                        if event.event == "PB_CONNECT" || event.data.contains("\"clientId\"") {
                            guard let clientId = Self.clientId(from: event.data) else {
                                // Connected but no parseable clientId (protocol drift) → fail so the
                                // coordinator reconnects/backs off rather than consuming forever.
                                throw PocketBaseError.network("realtime: PB_CONNECT without clientId")
                            }
                            try await Self.subscribe(baseURL: baseURL, session: session,
                                                     clientId: clientId, token: token)
                            subscribed = true
                            continue
                        }
                        if subscribed, event.event == "tasks" || event.data.contains("\"action\"") {
                            continuation.yield(event.data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in streamTask.cancel() }
        }
    }

    private static func subscribe(baseURL: String, session: URLSession, clientId: String, token: String) async throws {
        var req = URLRequest(url: URL(string: baseURL + "/api/realtime")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["clientId": clientId, "subscriptions": ["tasks"]])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PocketBaseError.network("realtime subscribe failed")
        }
    }

    private static func clientId(from data: String) -> String? {
        guard let d = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["clientId"] as? String
    }
}
