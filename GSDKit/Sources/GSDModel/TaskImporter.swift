import Foundation

public enum ImportError: Error, Equatable {
    case payloadTooLarge(bytes: Int)
    case tooManyTasks(count: Int)
    case malformed(String)
}

/// The outcome of a pure import parse: the tasks the store should write, plus how many
/// raw task entries were skipped (failed lenient decode).
public struct ImportResult: Equatable, Sendable {
    public let tasks: [Task]
    public let skipped: Int
    public init(tasks: [Task], skipped: Int) { self.tasks = tasks; self.skipped = skipped }
}

/// Pure import parsing (design-spec §3): lenient per-task decode (unknown keys ignored,
/// missing optionals defaulted, a structurally-broken task skipped+counted), enforced
/// limits, and the two import modes. `merge` regenerates colliding ids and remaps internal
/// references; `replace` returns the parsed set verbatim. The store does the writing.
public enum TaskImporter {
    public static let maxImportTasks = 10_000
    public static let maxImportBytes = 10 * 1024 * 1024   // ~10 MB

    /// Replace-mode parse: validate limits + lenient-decode; return the set as-is.
    public static func replace(from data: Data) throws -> ImportResult {
        try parse(data)
    }

    /// Merge-mode parse: as `replace`, then two-phase id-remap of any task whose id
    /// collides with an existing store id, remapping `dependencies`/`parentTaskId`
    /// references through the complete map (forward references handled).
    public static func merge(from data: Data, existingIDs: Set<String>,
                             newID: () -> String) throws -> ImportResult {
        let parsed = try parse(data)

        // Phase 1: assign new ids to colliding imported tasks; a new id must collide with
        // neither existing ids, other imported ids, nor already-assigned new ids.
        var reserved = existingIDs.union(parsed.tasks.map(\.id))
        var remap: [String: String] = [:]
        for task in parsed.tasks where existingIDs.contains(task.id) {
            var candidate = newID()
            while reserved.contains(candidate) { candidate = newID() }
            remap[task.id] = candidate
            reserved.insert(candidate)
        }

        // Phase 2: rewrite ids + internal references through the complete map.
        let remapped = parsed.tasks.map { task -> Task in
            var t = task
            t.id = remap[task.id] ?? task.id
            t.dependencies = task.dependencies.map { remap[$0] ?? $0 }
            if let p = task.parentTaskId { t.parentTaskId = remap[p] ?? p }
            return t
        }
        return ImportResult(tasks: remapped, skipped: parsed.skipped)
    }

    // MARK: parsing

    /// Decode the envelope leniently: read `tasks` as raw JSON values, decode each task
    /// independently (skip+count failures), enforce the byte + count limits.
    private static func parse(_ data: Data) throws -> ImportResult {
        guard data.count <= maxImportBytes else { throw ImportError.payloadTooLarge(bytes: data.count) }

        // Decode the envelope structurally, leaving `tasks` as opaque per-task containers
        // so one bad task doesn't fail the whole decode.
        let envelope: LenientEnvelope
        do {
            envelope = try TaskExport.decoder().decode(LenientEnvelope.self, from: data)
        } catch {
            throw ImportError.malformed("\(error)")
        }

        guard envelope.tasks.count <= maxImportTasks else {
            throw ImportError.tooManyTasks(count: envelope.tasks.count)
        }

        var tasks: [Task] = []
        var skipped = 0
        for raw in envelope.tasks {
            if let task = raw.decoded { tasks.append(task) } else { skipped += 1 }
        }
        return ImportResult(tasks: tasks, skipped: skipped)
    }

    /// Envelope whose `tasks` are decoded one-at-a-time via `LenientTask` so a single
    /// malformed entry is isolated. Unknown envelope keys are ignored by `Codable` default.
    private struct LenientEnvelope: Decodable {
        let tasks: [LenientTask]
    }
    /// Wraps a per-task decode attempt. `Task` already defaults its optional fields and
    /// `Codable` ignores unknown keys, so a missing-key or extra-key task decodes fine;
    /// only a structurally-broken task (wrong value type) yields `nil`.
    private struct LenientTask: Decodable {
        let decoded: Task?
        init(from decoder: Decoder) throws {
            decoded = try? Task(from: decoder)
        }
    }
}

extension TaskExport {
    /// Reuse the export decoder (fractional-seconds ISO-8601) for imports.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO-8601 date: \(s)")
            }
            return date
        }
        return decoder
    }
}
