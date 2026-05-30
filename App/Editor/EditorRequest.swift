import GSDModel

/// What the editor sheet was opened to do. `Identifiable` so it drives `.sheet(item:)`.
enum EditorRequest: Identifiable {
    case new(Quadrant, prefill: ParsedCapture?)
    case edit(Task)

    var id: String {
        switch self {
        case .new(let q, _): "new-\(q.rawValue)"
        case .edit(let t): t.id
        }
    }
}
