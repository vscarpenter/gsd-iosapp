import Foundation
import GRDB
import GSDModel

/// GRDB row for a CUSTOM smart view. Scalars map directly; `criteria` is stored as a
/// JSON string (same GSDJSON coding as TaskRecord's collections — increment spec §3.3).
/// `isBuiltIn` is persisted but is always `false` for stored rows (the 9 built-ins live
/// in-code as `BuiltInSmartViews.all` and are never written here).
struct SmartViewRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "smartViews"

    var id: String
    var name: String
    var icon: String
    var criteria: String      // JSON
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date
}

extension SmartViewRecord {
    init(_ view: SmartView, createdAt: Date, updatedAt: Date) throws {
        id = view.id
        name = view.name
        icon = view.icon
        criteria = try GSDJSON.string(view.criteria)
        isBuiltIn = false
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func toDomain() throws -> SmartView {
        SmartView(id: id, name: name, icon: icon,
                  criteria: try GSDJSON.value(FilterCriteria.self, criteria),
                  isBuiltIn: false)
    }
}
