import SwiftUI
import GSDModel

/// The editor's due date controls, shared with the weekly sweep so "New date" and "Add date" use
/// the same control, including All day and time of day (D-1): a day picker that keeps the time
/// already set, an All day switch, and a time picker while All day is off.
struct DueDateFields: View {
    @Binding var dueDate: Date

    /// The time picked when All day is switched off; the user can change it right away.
    private static let defaultDueTime: (hour: Int, minute: Int) = (9, 0)

    var body: some View {
        // Picking a day keeps the time already set (D-1), like Android's date picker.
        DatePicker(String(localized: "Due"),
                   selection: Binding(get: { dueDate }, set: { picked in
                       dueDate = DueTime.onDate(dueDate, to: Calendar.current.dateComponents([.year, .month, .day], from: picked),
                                                calendar: .current)
                   }),
                   displayedComponents: .date)
        Toggle(String(localized: "All day"), isOn: Binding(
            get: { DueTime.isAllDay(dueDate, calendar: .current) },
            set: { allDay in dueDate = DueTime.atTime(dueDate, allDay ? nil : Self.defaultDueTime, calendar: .current) }
        ))
        .tint(Surface.tint)   // toggles read the single interactive tint, not a third "on" color
        if !DueTime.isAllDay(dueDate, calendar: .current) {
            DatePicker(String(localized: "Due time"),
                       selection: Binding(get: { dueDate }, set: { picked in
                           let t = Calendar.current.dateComponents([.hour, .minute], from: picked)
                           dueDate = DueTime.atTime(dueDate, (t.hour ?? 0, t.minute ?? 0), calendar: .current)
                       }),
                       displayedComponents: .hourAndMinute)
        }
    }
}

/// The preset chips under the editor's date controls (Today, Tomorrow, and so on), shared the same way.
struct DueDatePresetRow: View {
    @Binding var dueDate: Date?
    /// The sweep's date control sets a new date and leaves clearing one to the editor.
    var offersNone = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DueDatePreset.allCases.filter { offersNone || $0 != .none }, id: \.self) { preset in
                let resolved = DueDatePresets.resolve(preset, today: .now, calendar: .current)
                let isSelected = Self.sameDay(dueDate, resolved)
                Button(preset.label) {
                    dueDate = resolved
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? QuadrantStyle.accent(.notUrgentImportant) : Surface.tint)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isSelected ? QuadrantStyle.wash(.notUrgentImportant) : Surface.sunken,
                            in: Capsule())
                .buttonStyle(.plain)
            }
        }
    }

    /// Whether two optional dates fall on the same calendar day (nil ≍ nil = "None").
    private static func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return Calendar.current.isDate(x, inSameDayAs: y)
        default: return false
        }
    }
}
