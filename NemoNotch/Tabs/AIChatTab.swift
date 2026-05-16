import SwiftUI

struct AIChatTab: View {
    @Environment(AICLIMonitorService.self) var aiService
    @State private var selectedSessionId: String?

    private var allSessions: [AISessionState] {
        aiService.store.sortedSessions
    }

    private var anyHookInstalled: Bool {
        aiService.anyHookInstalled
    }

    private var workingCount: Int {
        allSessions.count(where: { $0.status == .working })
    }

    private var waitingCount: Int {
        allSessions.count(where: { $0.status == .waiting })
    }

    private var idleCount: Int {
        allSessions.count(where: { $0.status == .idle })
    }

    private var dominantSource: AISource? {
        guard let first = allSessions.first?.source,
              allSessions.allSatisfy({ $0.source == first }) else {
            return nil
        }
        return first
    }

    private var consoleTitle: String {
        switch dominantSource {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .none: "AI Sessions"
        }
    }

    private var consoleSummary: String {
        let activeParts = [
            waitingCount > 0 ? "\(waitingCount) waiting" : nil,
            workingCount > 0 ? "\(workingCount) working" : nil,
            idleCount > 0 && workingCount + waitingCount == 0 ? "\(idleCount) idle" : nil,
        ].compactMap(\.self)

        if activeParts.isEmpty {
            return "\(allSessions.count) sessions"
        }
        return activeParts.joined(separator: " · ")
    }

    private var headerMeterSessions: [AISessionState] {
        Array(
            allSessions
                .filter { $0.lastContextTokens > 0 }
                .sorted { $0.contextPercent > $1.contextPercent }
                .prefix(2)
        )
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
            Text("ai.hooks_not_installed")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Button("ai.install_hooks") {
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
            Text("ai.no_active_sessions")
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
            Text(aiService.serverRunning ? "ai.unix_socket_ready" : "ai.hook_service_not_started")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
        }
        .padding(.top, 4)
    }

    private var sessionList: some View {
        VStack(spacing: 12) {
            aiConsoleHeader

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(allSessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.bottom, 10)
            }
            .notchScrollEdgeShadow(.vertical, thickness: 16, intensity: 0.30)
        }
        .padding(.horizontal, 2)
    }

    private var aiConsoleHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            consoleIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(consoleTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(consoleSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                if headerMeterSessions.isEmpty {
                    serverStatus
                } else {
                    ForEach(headerMeterSessions) { session in
                        compactContextMeter(session)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var consoleIcon: some View {
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
                if let dominantSource {
                    switch dominantSource {
                    case .claude:
                        ClaudeCrabIcon(size: 22, color: .white)
                    case .gemini:
                        Image(systemName: "sparkle")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: NotchTheme.accent.opacity(0.32), radius: 16, y: 8)
    }

    private func compactContextMeter(_ session: AISessionState) -> some View {
        HStack(spacing: 8) {
            Text(meterLabel(for: session))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 34, alignment: .trailing)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(NotchTheme.rail)
                    Capsule(style: .continuous)
                        .fill(NotchTheme.accentText)
                        .frame(width: max(geo.size.width * CGFloat(session.contextPercent), 4))
                }
            }
            .frame(width: 68, height: 7)

            Text(String(format: "%.0f%%", session.contextPercent * 100))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(NotchTheme.accentText)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func meterLabel(for session: AISessionState) -> String {
        if let model = session.displayModel {
            let parts = model.split(separator: " ")
            if let last = parts.last {
                return String(last.prefix(5))
            }
        }
        return "ctx"
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
                    .modifier(PulseModifier(isActive: session
                            .status == .working || approvalContext(for: session) != nil))
                    .padding(.top, 4)
                    .frame(maxHeight: .infinity, alignment: .top)
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
                Text("ai.no_messages")
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
                        withAnimation(.spring(
                            duration: NotchConstants.tabSwitchSpringDuration,
                            bounce: NotchConstants.tabSwitchSpringBounce
                        )) {
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
                Text("ai.awaiting_approval \(ctx.toolName)")
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
            Button("ai.deny") { aiService.respondToPermission(sessionId: session.id, approved: false) }
                .buttonStyle(NotchPillButtonStyle())
            Button("ai.allow") { aiService.respondToPermission(sessionId: session.id, approved: true) }
                .buttonStyle(NotchPillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .notchCard(radius: 8, fill: NotchTheme.accentSoft)
    }

    private func sessionRow(_ session: AISessionState) -> some View {
        let approval = approvalContext(for: session)

        return Button {
            selectedSessionId = session.id
        } label: {
            HStack(alignment: .center, spacing: 11) {
                Circle()
                    .fill(dotColor(session.status))
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor(session.status).opacity(0.86), radius: 8)
                    .modifier(PulseModifier(isActive: session.status == .working || approval != nil))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)

                        sessionStatusPill(session)

                        if let event = session.lastEventName {
                            eventTag(event)
                        }

                        if session.status == .working, let tool = session.currentTool {
                            toolPill(tool)
                        }

                        if let model = session.displayModel {
                            modelPill(model)
                        }

                        Spacer(minLength: 0)

                        Text(timeAgo(session.lastEventTime))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchTheme.textTertiary)
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
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)

                if let ctx = approval {
                    approvalButtons(for: session, ctx: ctx)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(approval != nil ? NotchTheme.surfaceWarm : NotchTheme.surfaceSubtle)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            approval != nil ? NotchTheme.accentStroke : NotchTheme.strokeStrong,
                            lineWidth: approval != nil ? 1 : 0.7
                        )
                )
        )
        .shadow(color: approval != nil ? NotchTheme.accent.opacity(0.12) : .clear, radius: 14, y: 6)
    }

    @ViewBuilder
    private func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, color: NotchTheme.accentText)
        case .gemini:
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    private func eventTag(_ event: String) -> some View {
        let (label, color) = eventTagStyle(event)
        return Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.96))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
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

    private func sessionStatusPill(_ session: AISessionState) -> some View {
        let label: String = {
            if approvalContext(for: session) != nil { return "Approval" }
            switch session.status {
            case .idle: return "Idle"
            case .working: return "Working"
            case .waiting: return "Waiting for input"
            }
        }()

        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(statusColor(session.status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor(session.status).opacity(0.16))
            .clipShape(Capsule(style: .continuous))
    }

    private func modelPill(_ model: String) -> some View {
        Text(model)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(NotchTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NotchTheme.surfaceEmphasis)
            .clipShape(Capsule(style: .continuous))
    }

    private func toolPill(_ tool: String) -> some View {
        Text(tool)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(ToolStyle.color(tool).opacity(0.95))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ToolStyle.color(tool).opacity(0.14))
            .clipShape(Capsule(style: .continuous))
    }

    private func dotColor(_ status: ClaudeStatus) -> Color {
        statusColor(status)
    }

    private func statusColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .idle: NotchTheme.textTertiary
        case .working: NotchTheme.accentText
        case .waiting: NotchTheme.accent
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "ai.time_just_now") }
        let minutes = Int(interval / 60)
        if minutes < 60 { return String(format: String(localized: "ai.time_minutes_ago"), minutes) }
        return String(format: String(localized: "ai.time_hours_ago"), minutes / 60)
    }

    private func approvalContext(for session: AISessionState) -> PermissionContext? {
        if case let .waitingForApproval(ctx) = session.phase { return ctx }
        return nil
    }

    private func subagentTools(for message: ChatMessage, session: AISessionState) -> [SubagentToolCall]? {
        guard let toolName = message.toolName,
              ["Task", "Agent", "invoke_subagent"].contains(toolName) else { return nil }
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
                    Text("ai.requires_input")
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
                        Text("ai.deny")
                    }
                    .buttonStyle(NotchPillButtonStyle())

                    Button {
                        aiService.respondToPermission(sessionId: session.id, approved: true)
                    } label: {
                        Text("ai.allow")
                    }
                    .buttonStyle(NotchPillButtonStyle(prominent: true))
                }
            }
        }
    }

    // MARK: - Context Progress Bar

    private func contextBar(session: AISessionState) -> some View {
        let percent = session.contextPercent
        let barColor: Color = percent > 0.8 ? .red : NotchTheme.accentText

        return VStack(spacing: 4) {
            HStack {
                Text("ctx")
                    .foregroundStyle(NotchTheme.textMuted)
                Spacer()
                Text("\(session.contextTokenDisplay) / \(session.contextLimitDisplay)")
                    .foregroundStyle(NotchTheme.textMuted)
                Text(String(format: "%.0f%%", percent * 100))
                    .foregroundStyle(barColor.opacity(0.85))
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(NotchTheme.rail)
                    Capsule(style: .continuous)
                        .fill(barColor.opacity(0.88))
                        .frame(width: percent > 0 ? max(geo.size.width * CGFloat(percent), 3) : 0)
                }
            }
            .frame(height: 5)
        }
    }

    private func sessionById(_ id: String) -> AISessionState? {
        aiService.store.get(id)
    }
}
