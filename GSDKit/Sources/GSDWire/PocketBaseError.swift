import Foundation

/// Typed errors from the PocketBase client (§8). `public` — the App surfaces these.
public enum PocketBaseError: Error, Equatable {
    case network(String)
    case http(status: Int, body: String)
    case pocketBase(status: Int, message: String)
    case decoding(String)
}

/// PocketBase's standard error envelope (internal — only the client decodes it).
struct PBErrorEnvelope: Decodable { let message: String }
