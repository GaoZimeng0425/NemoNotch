import SwiftUI

struct ClaudeTab: View {
    @Environment(ClaudeCodeService.self) var claudeService

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
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Button("安装 Hooks") {
                claudeService.installHooks()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("无活跃会话")
                .font(.system(size: 11))
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
            Text(claudeService.serverRunning ? "Unix Socket 已就绪" : "Hook 服务未启动")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.top, 4)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(claudeService.sessions.values.sorted { $0.lastEventTime > $1.lastEventTime })) { session in
                    sessionRow(session)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func sessionRow(_ session: ClaudeState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ToolStyle.color(session.currentTool).opacity(0.2))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: ToolStyle.icon(session.currentTool))
                        .font(.system(size: 10))
                        .foregroundStyle(ToolStyle.color(session.currentTool))
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let event = session.lastEventName {
                        eventTag(event)
                    }
                    if session.status == .working, let tool = session.currentTool {
                        Text(tool)
                            .font(.system(size: 10))
                            .foregroundStyle(ToolStyle.color(tool))
                            .lineLimit(1)
                    }
                }
                if let msg = session.lastUserMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                } else if let msg = session.lastMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let cwd = session.cwd {
                        Text(URL(fileURLWithPath: cwd).lastPathComponent)
                            .lineLimit(1)
                    }
                    Text(timeAgo(session.lastEventTime))
                    if session.totalTokens > 0 {
                        Text("· \(session.tokenDisplay)")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
            }

            Spacer(minLength: 0)

            if let ctx = approvalContext(for: session) {
                approvalButtons(for: session, ctx: ctx)
            } else {
                Circle()
                    .fill(dotColor(session.status))
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier(isActive: session.status == .working))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(approvalContext(for: session) != nil ? .orange.opacity(0.08) : .white.opacity(0.06))
        )
    }

    private func eventTag(_ event: String) -> some View {
        let (label, color) = eventTagStyle(event)
        return Text(label)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.6))
            .clipShape(Capsule())
    }

    private func eventTagStyle(_ event: String) -> (String, Color) {
        switch event {
        case "PreToolUse": return ("PreToolUse", .orange)
        case "PostToolUse": return ("PostToolUse", .blue)
        case "Stop": return ("Stop", .green)
        case "Notification": return ("Notification", .yellow)
        case "PermissionRequest": return ("Permission", .red)
        case "UserPromptSubmit": return ("Prompt", .purple)
        case "SessionStart": return ("Start", .cyan)
        default: return (event, .gray)
        }
    }

    private func dotColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .idle: .gray
        case .working: .green
        case .waiting: .yellow
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    private func approvalContext(for session: ClaudeState) -> PermissionContext? {
        if case .waitingForApproval(let ctx) = session.phase { return ctx }
        return nil
    }

    private func approvalButtons(for session: ClaudeState, ctx: PermissionContext) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Text(ctx.toolName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                if !ctx.displayInput.isEmpty {
                    Text(ctx.displayInput)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 4) {
                if ctx.isInteractiveTool {
                    Text("需要输入")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08))
                        .clipShape(Capsule())
                } else {
                    Button {
                        claudeService.respondToPermission(sessionId: session.id, approved: false)
                    } label: {
                        Text("拒绝")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        claudeService.respondToPermission(sessionId: session.id, approved: true)
                    } label: {
                        Text("允许")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
