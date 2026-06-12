import Foundation
import GSDModel

extension Task {
    var shareText: String {
        var lines = [title, quadrant.title]
        if let dueDate {
            lines.append(DateFormatter.localizedString(from: dueDate, dateStyle: .medium, timeStyle: .none))
        }
        if !tags.isEmpty {
            lines.append(tags.map { "#\($0)" }.joined(separator: " "))
        }
        if !description.isEmpty {
            lines.append("")
            lines.append(description)
        }
        return lines.joined(separator: "\n")
    }
}
