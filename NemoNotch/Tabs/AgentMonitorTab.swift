import SwiftUI

struct AgentMonitorTab: View {
    @Environment(OpenClawService.self) var openClawService
    @Environment(HermesService.self) var hermesService
    @State private var expandedAgentId: String?

    private var monitors: [any MultiAgentMonitor] {
        var list: [any MultiAgentMonitor] = []
        if openClawService.isInstalled { list.append(openClawService) }
        if hermesService.isInstalled { list.append(hermesService) }
        return list
    }

    var body: some View {
        if monitors.isEmpty {
            notInstalled
        } else if monitors.allSatisfy({ !$0.isOnline }) {
            offlineState
        } else {
            agentSections
        }
    }

    private var notInstalled: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("agents.not_installed")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("npm install -g openclaw@latest")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("agents.all_offline")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("agents.waiting_for_connection")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentSections: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(monitors.filter(\.isOnline), id: \.displayName) { monitor in
                    AgentMonitorSection(
                        monitor: monitor,
                        expandedAgentId: $expandedAgentId,
                        sessionMessages: monitor is HermesService ? (monitor as! HermesService).sessionMessages : nil
                    )
                }
            }
        }
        .notchScrollEdgeShadow(.vertical, thickness: 12, intensity: 0.36)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }
}

// MARK: - Agent Monitor Section

struct AgentMonitorSection: View {
    let monitor: any MultiAgentMonitor
    @Binding var expandedAgentId: String?
    let sessionMessages: [String: [ChatMessage]]?

    private var partitionedAgents: (active: [MonitoredAgent], idle: [MonitoredAgent]) {
        let sorted = monitor.agents.values.sorted { $0.lastEventTime > $1.lastEventTime }
        let active = sorted.filter { $0.state != .idle }
        let idle = sorted.filter { $0.state == .idle }
        return (active, idle)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if monitor is HermesService {
                    Image("HermesIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Text(monitor.iconEmoji)
                        .font(.system(size: 11))
                }
                Text(monitor.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)

            let (active, idle) = partitionedAgents

            ForEach(active) { agent in
                AgentRowView(
                    agent: agent,
                    isExpanded: expandedAgentId == agent.id,
                    messages: sessionMessages?[agent.id]
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedAgentId == agent.id {
                            expandedAgentId = nil
                        } else if sessionMessages?[agent.id] != nil {
                            expandedAgentId = agent.id
                        }
                    }
                }
            }

            if !idle.isEmpty {
                HStack {
                    Text("agents.idle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textMuted)
                    Divider()
                        .background(NotchTheme.stroke)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            ForEach(idle) { agent in
                AgentRowView(
                    agent: agent,
                    isExpanded: false,
                    messages: nil
                )
                .opacity(0.5)
            }
        }
    }
}

// MARK: - Agent Row

struct AgentRowView: View {
    let agent: MonitoredAgent
    let isExpanded: Bool
    let messages: [ChatMessage]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(NotchTheme.surfaceEmphasis)
                    .frame(width: 24, height: 24)
                    .overlay {
                        if agent.emoji.isEmpty, agent.name.hasPrefix("Hermes") {
                            Image("HermesIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                        } else {
                            Text(agent.emoji)
                                .font(.system(size: 13))
                        }
                    }
                    .modifier(PulseModifier(isActive: agent.state == .working || agent.state == .toolCalling))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)

                        AgentStateTag(state: agent.state)

                        if let msgs = messages, !msgs.isEmpty {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(NotchTheme.textTertiary)
                        }
                    }

                    if let tool = agent.currentTool, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTheme.accent)
                            .lineLimit(1)
                    }

                    if let msg = agent.lastMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTheme.textSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        if let workspace = agent.workspace {
                            Text(URL(fileURLWithPath: workspace).lastPathComponent)
                                .lineLimit(1)
                        }
                        Text(timeAgo(agent.lastEventTime))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTheme.textMuted)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if isExpanded, let messages {
                AgentMessagePreview(messages: messages)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "agents.time_just_now") }
        let minutes = Int(interval / 60)
        if minutes < 60 { return String(format: String(localized: "agents.time_minutes_ago"), minutes) }
        return String(format: String(localized: "agents.time_hours_ago"), minutes / 60)
    }
}

// MARK: - Agent Message Preview

struct AgentMessagePreview: View {
    let messages: [ChatMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .background(NotchTheme.stroke)
                .padding(.horizontal, 8)

            ForEach(Array(messages.suffix(10)), id: \.id) { msg in
                HStack(alignment: .top, spacing: 4) {
                    Text(iconForRole(msg))
                        .font(.system(size: 9))
                        .frame(width: 14)
                    Text(displayContent(for: msg))
                        .font(.system(size: 9))
                        .foregroundStyle(colorForRole(msg))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
    }

    private func iconForRole(_ msg: ChatMessage) -> String {
        switch msg.role {
        case .user: "\u{1F464}"
        case .assistant: msg.toolName != nil ? "\u{1F527}" : "\u{1F916}"
        case .tool, .toolResult: "\u{1F4CB}"
        case .system: "\u{2139}\u{FE0F}"
        }
    }

    private func colorForRole(_ msg: ChatMessage) -> Color {
        switch msg.role {
        case .user: NotchTheme.textPrimary
        case .assistant: msg.toolName != nil ? NotchTheme.accent : NotchTheme.textSecondary
        case .tool, .toolResult: NotchTheme.textTertiary
        case .system: NotchTheme.textMuted
        }
    }

    private func displayContent(for msg: ChatMessage) -> String {
        if let toolName = msg.toolName {
            let input = msg.toolInput.map { _ in " \u{2026}" } ?? ""
            return "\(toolName)\(input)"
        }
        return String(msg.content.prefix(80))
    }
}

// MARK: - Agent State Tag

struct AgentStateTag: View {
    let state: AgentMonitorState

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.6))
            .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .idle: String(localized: "agents.state_idle")
        case .working: String(localized: "agents.state_working")
        case .speaking: String(localized: "agents.state_speaking")
        case .toolCalling: String(localized: "agents.state_tool_calling")
        case .error: String(localized: "agents.state_error")
        }
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .working: .blue
        case .speaking: .green
        case .toolCalling: .orange
        case .error: .red
        }
    }
}
