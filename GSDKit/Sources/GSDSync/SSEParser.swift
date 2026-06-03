import Foundation

/// Incremental SSE (`text/event-stream`) line parser. Feed it lines (no trailing newline); it
/// emits a completed `Event` on a blank line. Pure + synchronous → fully unit-testable; the
/// streaming reader (`PocketBaseRealtime`) feeds it lines from `URLSession.bytes.lines`.
/// PocketBase emits fields with NO space after the colon (`id:abc`), so the optional-space strip
/// below tolerates both `field:value` and `field: value` (Probe P1, 2026-06-03).
struct SSEParser {
    struct Event: Equatable { var event: String?; var data: String; var id: String? }

    private var eventName: String?
    private var dataLines: [String] = []
    private(set) var lastEventId: String?

    mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            guard !dataLines.isEmpty || eventName != nil else { return nil }
            let event = Event(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventId)
            eventName = nil; dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil }   // comment / heartbeat
        let (field, value) = Self.split(line)
        switch field {
        case "event": eventName = value
        case "data":  dataLines.append(value)
        case "id":    lastEventId = value
        default:      break
        }
        return nil
    }

    /// Split `field: value`; per the SSE spec, exactly one leading space after the colon is removed.
    private static func split(_ line: String) -> (String, String) {
        guard let idx = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<idx])
        var value = String(line[line.index(after: idx)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
