import SwiftUI

struct AgentMonitorTab: View {
    @Environment(AgentMonitorRegistry.self) var registry
    @Environment(OpenClawService.self) var openClaw
    @State private var expandedAgentId: String?

    private var monitors: [any MultiAgentMonitor] {
        registry.installedMonitors
    }

    var body: some View {
        if monitors.isEmpty {
            notInstalled
        } else if monitors.allSatisfy({ !$0.isOnline }) {
            if openClaw.pendingApproval != nil {
                OpenClawApprovalCard()
            } else {
                offlineState
            }
        } else {
            // At least one monitor (e.g. Hermes) is online. Show its agents,
            // but float OpenClaw's approval card on top so the pairing CTA
            // stays discoverable instead of getting eaten by another online
            // service.
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
                if openClaw.pendingApproval != nil {
                    OpenClawApprovalBanner()
                }
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

// MARK: - Agent Monitor Source Style

struct AgentMonitorSourceStyle {
    let label: String
    let shortLabel: String
    let iconEmoji: String
    let iconAssetName: String?
    let tint: Color
    let secondaryTint: Color
    let surface: Color
    let stroke: Color

    var gradientColors: [Color] {
        [tint, secondaryTint]
    }

    init(displayName: String, iconEmoji: String, iconAssetName: String?) {
        let normalized = displayName.lowercased()
        self.iconEmoji = iconEmoji
        self.iconAssetName = iconAssetName

        if normalized.contains("hermes") {
            label = "Hermes"
            shortLabel = "H"
            tint = Color(red: 0.44, green: 0.73, blue: 1.0)
            secondaryTint = Color(red: 0.23, green: 0.42, blue: 0.95)
            surface = Color(red: 0.035, green: 0.080, blue: 0.145).opacity(0.72)
            stroke = tint.opacity(0.38)
        } else if normalized.contains("openclaw") {
            label = "OpenClaw"
            shortLabel = "OC"
            tint = NotchTheme.accentText
            secondaryTint = NotchTheme.accentHot
            surface = NotchTheme.surfaceWarm
            stroke = NotchTheme.accentStroke
        } else {
            label = displayName
            shortLabel = String(displayName.prefix(2)).uppercased()
            tint = NotchTheme.accentText
            secondaryTint = NotchTheme.accentHot
            surface = NotchTheme.surfaceWarm
            stroke = NotchTheme.accentStroke
        }
    }
}

struct AgentMonitorSourceIcon: View {
    let style: AgentMonitorSourceStyle
    let size: CGFloat

    var body: some View {
        if let asset = style.iconAssetName {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(size * 0.18, 3), style: .continuous))
        } else if !style.iconEmoji.isEmpty {
            Text(style.iconEmoji)
                .font(.system(size: size))
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
    }
}

struct AgentMonitorSourceBadge: View {
    let style: AgentMonitorSourceStyle
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if !compact {
                AgentMonitorSourceIcon(style: style, size: 10)
            }
            Text(compact ? style.shortLabel : style.label)
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(style.tint)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, 3)
        .background(style.tint.opacity(0.14))
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Agent Monitor Section

struct AgentMonitorSection: View {
    let monitor: any MultiAgentMonitor
    @Binding var expandedAgentId: String?
    let sessionMessages: [String: [ChatMessage]]

    private var sourceStyle: AgentMonitorSourceStyle {
        AgentMonitorSourceStyle(
            displayName: monitor.displayName,
            iconEmoji: monitor.iconEmoji,
            iconAssetName: monitor.iconAssetName
        )
    }

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
            monitorHeader(activeCount: active.count, sourceStyle: sourceStyle)

            ForEach(active) { agent in
                AgentRowView(
                    agent: agent,
                    sourceStyle: sourceStyle,
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
                    sourceStyle: sourceStyle,
                    isExpanded: false,
                    messages: nil
                )
                .opacity(0.5)
            }
        }
    }

    private func monitorHeader(activeCount: Int, sourceStyle: AgentMonitorSourceStyle) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: sourceStyle.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    AgentMonitorSourceIcon(style: sourceStyle, size: 26)
                }
                .shadow(color: sourceStyle.tint.opacity(0.30), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(monitor.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    AgentMonitorSourceBadge(style: sourceStyle, compact: true)
                }
                Text(summaryText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if activeCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceStyle.tint)
                        .frame(width: 7, height: 7)
                        .shadow(color: sourceStyle.tint.opacity(0.76), radius: 8)
                    Text("\(activeCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(sourceStyle.tint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(sourceStyle.surface)
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
    let sourceStyle: AgentMonitorSourceStyle
    let isExpanded: Bool
    let messages: [ChatMessage]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                sourceMark

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        AgentMonitorSourceBadge(style: sourceStyle)

                        Text(agent.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)

                        AgentStateTag(state: agent.state, tint: sourceStyle.tint)

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
                            .foregroundStyle(sourceStyle.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(sourceStyle.tint.opacity(0.14))
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
                .fill(agent.state == .idle ? NotchTheme.surfaceSubtle : sourceStyle.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            agent.state == .idle ? NotchTheme.strokeStrong : sourceStyle.stroke,
                            lineWidth: agent.state == .idle ? 0.7 : 1
                        )
                )
        )
        .shadow(color: agent.state == .idle ? .clear : sourceStyle.tint.opacity(0.10), radius: 14, y: 6)
    }

    private var sourceMark: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(sourceStyle.tint.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(sourceStyle.tint.opacity(0.34), lineWidth: 0.8)
            )
            .frame(width: 34, height: 34)
            .overlay {
                AgentMonitorSourceIcon(style: sourceStyle, size: 18)
            }
            .overlay(alignment: .bottomTrailing) {
                statusDot
                    .offset(x: 3, y: 3)
            }
            .frame(width: 40, height: 40, alignment: .topLeading)
    }

    private var statusDot: some View {
        let active = agent.state == .working || agent.state == .toolCalling

        return ZStack {
            if active {
                Circle()
                    .fill(stateColor.opacity(0.18))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(NotchTheme.panelBase.opacity(0.92), lineWidth: 1.5))
                .shadow(color: stateColor.opacity(0.55), radius: 5)
        }
        .frame(width: 14, height: 14)
    }

    private var stateColor: Color {
        switch agent.state {
        case .idle: NotchTheme.textTertiary
        case .working, .toolCalling, .speaking: sourceStyle.tint
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
        case .thought: "lightbulb.fill"
        case .tool, .toolResult: "doc.text.fill"
        case .system: "info.circle.fill"
        }
    }

    private func colorForRole(_ msg: ChatMessage) -> Color {
        switch msg.role {
        case .user: NotchTheme.textPrimary
        case .assistant: msg.toolName != nil ? NotchTheme.accent : NotchTheme.textSecondary
        case .thought: Color.orange.opacity(0.8)
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
    var tint: Color = NotchTheme.accentText

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
        case .working: tint
        case .speaking: tint
        case .toolCalling: tint
        case .error: .red
        }
    }
}

// MARK: - OpenClaw Approval — Buttons (shared)

private struct OpenClawRunButton: View {
    @Environment(OpenClawService.self) var openClaw
    var compact: Bool = false

    var body: some View {
        Button {
            openClaw.approveSelf()
        } label: {
            HStack(spacing: 3) {
                if openClaw.isApproving {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.black.opacity(0.85))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: compact ? 8 : 9))
                }
                Text(openClaw.isApproving
                    ? "agents.openclaw.approval.button.running"
                    : "agents.openclaw.approval.button.run")
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 4)
            .background(Capsule().fill(NotchTheme.accent))
            .foregroundStyle(.black.opacity(0.85))
        }
        .buttonStyle(.plain)
        .disabled(openClaw.isApproving)
    }
}

private struct OpenClawCopyButton: View {
    @Environment(OpenClawService.self) var openClaw
    @State private var justCopied = false
    var compact: Bool = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(openClaw.approveCommandString, forType: .string)
            justCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                justCopied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: compact ? 8 : 9))
                Text(justCopied
                    ? "agents.openclaw.approval.button.copied"
                    : "agents.openclaw.approval.button.copy")
                    .font(.system(size: compact ? 9 : 10))
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 4)
            .foregroundStyle(NotchTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OpenClaw Approval Banner (compact, inline above agent sections)

private struct OpenClawApprovalBanner: View {
    @Environment(OpenClawService.self) var openClaw

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14))
                .foregroundStyle(NotchTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("agents.openclaw.approval.title")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                if let info = openClaw.pendingApproval {
                    Text(verbatim: String(info.deviceId.prefix(12)) + "…")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }
            Spacer(minLength: 4)
            OpenClawRunButton(compact: true)
            OpenClawCopyButton(compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }
}

// MARK: - OpenClaw Approval Card (full-tab, when nothing else is online)

private struct OpenClawApprovalCard: View {
    @Environment(OpenClawService.self) var openClaw

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(NotchTheme.accent)
            Text("agents.openclaw.approval.title")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text("agents.openclaw.approval.run_in_terminal")
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
            Text(verbatim: openClaw.approveCommandString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(NotchTheme.surfaceSubtle))
                .padding(.horizontal, 16)
            HStack(spacing: 8) {
                OpenClawRunButton()
                OpenClawCopyButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
