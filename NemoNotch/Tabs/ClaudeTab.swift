import SwiftUI

struct ClaudeTab: View {
    let claudeService: ClaudeCodeService

    var body: some View {
        if !claudeService.isHookInstalled {
            installPrompt
        } else if claudeService.sessions.isEmpty {
            idleState
        } else {
            sessionList
        }
    }

    private var installPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("Claude Code Hooks 未安装")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Button("安装 Hooks") {
                claudeService.installHooks()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("无活跃会话")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            serverStatus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(claudeService.serverRunning ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            if claudeService.serverRunning {
                Text("监听端口 \(claudeService.serverPort)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                Text("Hook 服务未启动")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.top, 4)
    }

    private var sessionList: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(claudeService.sessions.values.sorted { $0.lastEventTime > $1.lastEventTime })) { session in
                        sessionRow(session)
                    }
                }
            }

            Button {
                claudeService.uninstallHooks()
            } label: {
                Text("卸载 Hooks")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func sessionRow(_ session: ClaudeState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon(session.currentTool))
                .font(.system(size: 11))
                .foregroundStyle(toolColor(session.currentTool))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(projectName(session))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let event = session.lastEventName {
                        eventTag(event)
                    }
                    if session.status == .working, let tool = session.currentTool {
                        Text(tool)
                            .font(.system(size: 10))
                            .foregroundStyle(toolColor(tool))
                            .lineLimit(1)
                    }
                }
                if let msg = session.lastMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(formatTime(session.sessionStart))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(durationLabel(session))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(timeAgo(session.lastEventTime))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func eventTag(_ event: String) -> some View {
        let (label, color) = eventTagStyle(event)
        return Text(label)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.7))
            .clipShape(Capsule())
    }

    private func eventTagStyle(_ event: String) -> (String, Color) {
        switch event {
        case "PreToolUse": return ("PreToolUse", .orange)
        case "PostToolUse": return ("PostToolUse", .blue)
        case "Stop": return ("Stop", .green)
        case "Notification": return ("Notification", .yellow)
        case "UserPromptSubmit": return ("Prompt", .purple)
        case "SessionStart": return ("Start", .cyan)
        default: return (event, .gray)
        }
    }

    private func toolColor(_ tool: String?) -> Color {
        guard let tool else { return .gray }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" { return .cyan }
        if tool.hasPrefix("Write") || tool == "Edit" { return .red }
        if tool == "Bash" { return .green }
        if tool == "Agent" { return .purple }
        if tool.hasPrefix("Web") { return .teal }
        return .orange
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func toolIcon(_ tool: String?) -> String {
        guard let tool else { return "gearshape.fill" }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" {
            return "doc.text.magnifyingglass"
        }
        if tool.hasPrefix("Write") || tool == "Edit" {
            return "pencil"
        }
        if tool == "Bash" { return "terminal" }
        if tool == "Agent" { return "person.wave.2" }
        if tool.hasPrefix("Web") { return "globe" }
        return "gearshape.fill"
    }

    private func projectName(_ session: ClaudeState) -> String {
        if let folder = session.projectFolder { return folder }
        return "Session \(session.id.prefix(8))"
    }

    private func durationLabel(_ session: ClaudeState) -> String {
        let interval = Date().timeIntervalSince(session.sessionStart)
        let minutes = Int(interval / 60)
        if minutes < 1 { return "< 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func statusDot(_ status: ClaudeStatus) -> some View {
        Circle()
            .fill(dotColor(status))
            .frame(width: 8, height: 8)
            .modifier(PulseModifier(isActive: status == .working))
    }

    private func dotColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .idle: .gray
        case .working: .green
        case .waiting: .yellow
        }
    }

    private func statusLabel(_ session: ClaudeState) -> String {
        switch session.status {
        case .working:
            return session.currentTool ?? "思考中…"
        case .waiting:
            return "等待中"
        case .idle:
            return "空闲"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }
}

struct PulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isActive
            )
    }
}

struct GlowPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .opacity(0.6)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: true)
    }
}
