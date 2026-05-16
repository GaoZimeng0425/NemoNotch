import SwiftUI

struct AgentMonitorTab: View {
    @Environment(AgentMonitorRegistry.self) var registry
    @State private var expandedAgentId: String?

    private var monitors: [any MultiAgentMonitor] {
        registry.installedMonitors
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
            LazyVStack(spacing: 14) {
                ForEach(monitors.filter(\.isOnline), id: \.displayName) { monitor in
                    AgentMonitorSection(
                        monitor: monitor,
                        expandedAgentId: $expandedAgentId,
                        sessionMessages: monitor.sessionMessages
                    )
                }
            }
        }
        .notchScrollEdgeShadow(.vertical, thickness: 16, intensity: 0.30)
        .padding(.horizontal, 2)
        .padding(.bottom, 14)
    }
}

// MARK: - Agent Monitor Section

struct AgentMonitorSection: View {
    let monitor: any MultiAgentMonitor
    @Binding var expandedAgentId: String?
    let sessionMessages: [String: [ChatMessage]]

    private var partitionedAgents: (active: [MonitoredAgent], idle: [MonitoredAgent]) {
        let sorted = monitor.agents.values.sorted { $0.lastEventTime > $1.lastEventTime }
        let active = sorted.filter { $0.state != .idle }
        let idle = sorted.filter { $0.state == .idle }
        return (active, idle)
    }

    private var summaryText: String {
        let working = monitor.agents.values.count(where: { $0.state == .working || $0.state == .toolCalling })
        let speaking = monitor.agents.values.count(where: { $0.state == .speaking })
        let idle = monitor.agents.values.count(where: { $0.state == .idle })
        let parts = [
            working > 0 ? "\(working) working" : nil,
            speaking > 0 ? "\(speaking) speaking" : nil,
            idle > 0 && working + speaking == 0 ? "\(idle) idle" : nil,
        ].compactMap(\.self)

        if parts.isEmpty {
            return "\(monitor.agents.count) agents"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 8) {
            let (active, idle) = partitionedAgents
            monitorHeader(activeCount: active.count)

            ForEach(active) { agent in
                AgentRowView(
                    agent: agent,
                    isExpanded: expandedAgentId == agent.id,
                    messages: sessionMessages[agent.id]
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedAgentId == agent.id {
                            expandedAgentId = nil
                        } else if sessionMessages[agent.id] != nil {
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

    private func monitorHeader(activeCount: Int) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    if let asset = monitor.iconAssetName {
                        Image(asset)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Text(monitor.iconEmoji)
                            .font(.system(size: 24))
                    }
                }
                .shadow(color: NotchTheme.accent.opacity(0.32), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(summaryText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if activeCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(NotchTheme.accentText)
                        .frame(width: 7, height: 7)
                        .shadow(color: NotchTheme.accent.opacity(0.8), radius: 8)
                    Text("\(activeCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchTheme.accentText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(NotchTheme.surfaceWarm)
                .clipShape(Capsule(style: .continuous))
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Agent Row

struct AgentRowView: View {
    let agent: MonitoredAgent
    let isExpanded: Bool
    let messages: [ChatMessage]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: stateColor.opacity(0.82), radius: 8)
                    .modifier(PulseModifier(isActive: agent.state == .working || agent.state == .toolCalling))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)

                        AgentStateTag(state: agent.state)

                        if let msgs = messages, !msgs.isEmpty {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(NotchTheme.textTertiary)
                        }

                        Spacer(minLength: 0)

                        Text(timeAgo(agent.lastEventTime))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }

                    if let tool = agent.currentTool, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(NotchTheme.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(NotchTheme.accentSoft)
                            .clipShape(Capsule(style: .continuous))
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
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTheme.textMuted)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            if isExpanded, let messages {
                AgentMessagePreview(messages: messages)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(agent.state == .idle ? NotchTheme.surfaceSubtle : NotchTheme.surfaceWarm)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            agent.state == .idle ? NotchTheme.strokeStrong : NotchTheme.accentStroke,
                            lineWidth: agent.state == .idle ? 0.7 : 1
                        )
                )
        )
        .shadow(color: agent.state == .idle ? .clear : NotchTheme.accent.opacity(0.12), radius: 14, y: 6)
    }

    private var stateColor: Color {
        switch agent.state {
        case .idle: NotchTheme.textTertiary
        case .working, .toolCalling, .speaking: NotchTheme.accentText
        case .error: .red
        }
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
                    Image(systemName: symbolForRole(msg))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(colorForRole(msg))
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

    private func symbolForRole(_ msg: ChatMessage) -> String {
        switch msg.role {
        case .user: "person.fill"
        case .assistant: msg.toolName != nil ? "wrench.and.screwdriver.fill" : "cpu"
        case .tool, .toolResult: "doc.text.fill"
        case .system: "info.circle.fill"
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
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
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
        case .idle: NotchTheme.textTertiary
        case .working: NotchTheme.accentText
        case .speaking: NotchTheme.accentText
        case .toolCalling: NotchTheme.accentText
        case .error: .red
        }
    }
}
