import SwiftUI

enum ToolStyle {
    static func icon(_ tool: String?) -> String {
        guard let tool else { return "gearshape.fill" }
        let normalized = tool.replacingOccurrences(of: "_", with: "").lowercased()
        if normalized == "askuserquestion" || normalized == "askuser" {
            return "questionmark.bubble.fill"
        }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" {
            return "doc.text.magnifyingglass"
        }
        if tool.hasPrefix("Write") || tool == "Edit" { return "pencil" }
        if tool == "Bash" { return "terminal" }
        if tool == "Agent" { return "person.wave.2" }
        if tool.hasPrefix("Web") { return "globe" }
        return "gearshape.fill"
    }

    static func color(_ tool: String?) -> Color {
        guard let tool else { return .orange }
        let normalized = tool.replacingOccurrences(of: "_", with: "").lowercased()
        if normalized == "askuserquestion" || normalized == "askuser" { return .orange }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" { return .cyan }
        if tool.hasPrefix("Write") || tool == "Edit" { return .red }
        if tool == "Bash" { return .green }
        if tool == "Agent" { return .purple }
        if tool.hasPrefix("Web") { return .teal }
        return .orange
    }
}
