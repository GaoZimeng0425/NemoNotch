import Foundation

struct SubagentToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let input: String
    var isCompleted: Bool
    let timestamp: Date

    var displayInput: String {
        guard !input.isEmpty else { return "" }
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
            for key in priorityKeys {
                if let value = json[key] as? String, !value.isEmpty {
                    return String(value.prefix(80))
                }
            }
        }
        return String(input.prefix(80))
    }
}

struct TaskContext: Identifiable, Equatable {
    let id: String
    var agentId: String?
    var description: String?
    var tools: [SubagentToolCall]
    let startTime: Date

    var activeToolCount: Int { tools.filter { !$0.isCompleted }.count }
    var completedToolCount: Int { tools.filter { $0.isCompleted }.count }
    var totalToolCount: Int { tools.count }
}

struct SubagentState: Equatable {
    var activeTasks: [String: TaskContext] = [:]

    var hasActiveTasks: Bool { !activeTasks.isEmpty }

    mutating func startTask(taskToolId: String, description: String?) {
        activeTasks[taskToolId] = TaskContext(
            id: taskToolId,
            description: description,
            tools: [],
            startTime: Date()
        )
    }

    mutating func setAgentId(taskToolId: String, agentId: String) {
        activeTasks[taskToolId]?.agentId = agentId
    }

    mutating func updateTools(taskToolId: String, tools: [SubagentToolCall]) {
        activeTasks[taskToolId]?.tools = tools
    }

    mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    func taskSummary() -> String? {
        guard !activeTasks.isEmpty else { return nil }
        let total = activeTasks.values.reduce(0) { $0 + $1.totalToolCount }
        let active = activeTasks.values.reduce(0) { $0 + $1.activeToolCount }
        if active > 0 {
            return "\(active) tools running"
        }
        return "\(total) tools completed"
    }
}
