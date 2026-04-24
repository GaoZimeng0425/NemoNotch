import SwiftUI

struct AIChatTab: View {
    @Environment(AICLIMonitorService.self) var aiService
    @State private var selectedSessionId: String?

    private var allSessions: [AISessionState] {
        let claudeSessions = Array(aiService.claudeProvider.sessions.values)
        let geminiSessions = Array(aiService.geminiProvider.sessions.values)
        return (claudeSessions + geminiSessions).sorted { $0.lastEventTime > $1.lastEventTime }
    }

    private var anyHookInstalled: Bool {
        aiService.claudeProvider.isHookInstalled || aiService.geminiProvider.isHookInstalled
    }

    var body: some View {
        if !anyHookInstalled {
            installPrompt
        } else if allSessions.isEmpty {
            idleState
        } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }

    private var installPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("AI CLI Hooks 未安装")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Button("安装 Hooks") {
                aiService.installHooks()
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("无活跃 AI 会话")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            serverStatus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(aiService.serverRunning ? Color.green : NotchTheme.accent)
                .frame(width: 6, height: 6)
            Text(aiService.serverRunning ? "Unix Socket 已就绪" : "Hook 服务未启动")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
        }
        .padding(.top, 4)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(allSessions.sorted { $0.lastEventTime > $1.lastEventTime }) { session in
                    sessionRow(session)
                }
            }
        }
        .notchScrollEdgeShadow(.vertical, thickness: 12, intensity: 0.36)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    private func chatDetail(session: AISessionState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedSessionId = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .buttonStyle(.plain)

                sourceIcon(session.source, size: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.projectFolder ?? "")
                            .foregroundStyle(NotchTheme.textMuted)
                        if let model = session.displayModel {
                            Text("· \(model)")
                                .foregroundStyle(NotchTheme.accent.opacity(0.88))
                        }
                        if session.totalTokens > 0 {
                            Text("· \(session.tokenDisplay)")
                                .foregroundStyle(NotchTheme.textMuted)
                        }
                    }
                    .font(.system(size: 9))
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(dotColor(session.status))
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier(isActive: session.status == .working || approvalContext(for: session) != nil))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if session.lastContextTokens > 0 {
                contextBar(session: session)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Divider().background(NotchTheme.stroke)

            if let ctx = approvalContext(for: session) {
                quickApprovalBar(session: session, ctx: ctx)
            }

            if session.messages.isEmpty {
                Spacer()
                Text("暂无消息")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textMuted)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(session.messages) { msg in
                                ChatMessageView(message: msg, subagentTools: subagentTools(for: msg, session: session))
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .notchScrollEdgeShadow(.vertical, thickness: 12, intensity: 0.36)
                    .onChange(of: session.messages.count) { _, _ in
                        withAnimation(.spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce)) {
                            proxy.scrollTo(session.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func quickApprovalBar(session: AISessionState, ctx: PermissionContext) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("等待审批: \(ctx.toolName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.accent)
                if let input = ctx.toolInput, !input.isEmpty {
                    Text(input)
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("拒绝") { aiService.respondToPermission(sessionId: session.id, approved: false) }
                .buttonStyle(NotchPillButtonStyle())
            Button("允许") { aiService.respondToPermission(sessionId: session.id, approved: true) }
                .buttonStyle(NotchPillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .notchCard(radius: 8, fill: NotchTheme.accentSoft)
    }

    private func sessionRow(_ session: AISessionState) -> some View {
        Button {
            selectedSessionId = session.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(ToolStyle.color(session.currentTool).opacity(0.2))
                    .frame(width: 24, height: 24)
                    .overlay {
                        sourceIcon(session.source, size: 12)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotchTheme.textPrimary)
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
                            .foregroundStyle(NotchTheme.textSecondary)
                            .lineLimit(2)
                    } else if let msg = session.lastMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTheme.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let cwd = session.cwd {
                            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                                .lineLimit(1)
                        }
                        Text(timeAgo(session.lastEventTime))
                        if let model = session.displayModel {
                            Text(model)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(NotchTheme.accent.opacity(0.9))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(NotchTheme.accentSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if session.totalTokens > 0 {
                            Text("· \(session.tokenDisplay)")
                                .foregroundStyle(NotchTheme.textMuted)
                        }
                        if session.subagentState.hasActiveTasks {
                            Text("· \(session.subagentState.taskSummary() ?? "")")
                                .foregroundStyle(NotchTheme.accent.opacity(0.82))
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTheme.textMuted)
                    if session.lastContextTokens > 0 {
                        contextBar(session: session)
                    }
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
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(approvalContext(for: session) != nil ? NotchTheme.accentSoft : NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }

    @ViewBuilder
    private func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size)
        case .gemini:
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(.blue)
        }
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
        case .waiting: NotchTheme.accent
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    private func approvalContext(for session: AISessionState) -> PermissionContext? {
        if case .waitingForApproval(let ctx) = session.phase { return ctx }
        return nil
    }

    private func subagentTools(for message: ChatMessage, session: AISessionState) -> [SubagentToolCall]? {
        guard let toolName = message.toolName, ["Task", "Agent", "invoke_subagent"].contains(toolName) else { return nil }
        for (_, task) in session.subagentState.activeTasks {
            if message.id.contains(task.id) {
                return task.tools
            }
        }
        return nil
    }

    private func approvalButtons(for session: AISessionState, ctx: PermissionContext) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Text(ctx.toolName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                if let input = ctx.toolInput, !input.isEmpty {
                    Text(input)
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 4) {
                if ctx.isInteractiveTool {
                    Text("需要输入")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NotchTheme.surfaceEmphasis)
                        .clipShape(Capsule(style: .continuous))
                } else {
                    Button {
                        aiService.respondToPermission(sessionId: session.id, approved: false)
                    } label: {
                        Text("拒绝")
                    }
                    .buttonStyle(NotchPillButtonStyle())

                    Button {
                        aiService.respondToPermission(sessionId: session.id, approved: true)
                    } label: {
                        Text("允许")
                    }
                    .buttonStyle(NotchPillButtonStyle(prominent: true))
                }
            }
        }
    }

    // MARK: - Context Progress Bar

    private func contextBar(session: AISessionState) -> some View {
        let percent = session.contextPercent
        let barColor: Color = {
            if percent > 0.8 { return .red }
            if percent > 0.5 { return .orange }
            return .blue
        }()

        return VStack(spacing: 3) {
            HStack {
                Text("ctx")
                    .foregroundStyle(NotchTheme.textMuted)
                Spacer()
                Text("\(session.contextTokenDisplay) / 200K")
                    .foregroundStyle(NotchTheme.textMuted)
                Text(String(format: "%.0f%%", percent * 100))
                    .foregroundStyle(barColor.opacity(0.7))
            }
            .font(.system(size: 8, design: .monospaced))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(NotchTheme.surface)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor.opacity(0.5))
                        .frame(width: percent > 0 ? max(geo.size.width * CGFloat(percent), 3) : 0)
                }
            }
            .frame(height: 3)
        }
    }

    private func sessionById(_ id: String) -> AISessionState? {
        aiService.claudeProvider.sessions[id] ?? aiService.geminiProvider.sessions[id]
    }
}
