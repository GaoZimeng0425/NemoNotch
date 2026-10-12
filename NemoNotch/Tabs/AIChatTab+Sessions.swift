import SwiftUI

extension AIChatTab {
    func chatDetail(session: AISessionState) -> some View {
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
                    HStack(spacing: 6) {
                        sourceBadge(session.source)
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Circle()
                            .fill(dotColor(session.status))
                            .frame(width: 6, height: 6)
                            .modifier(PulseModifier(isActive: session
                                    .status == .working || approvalContext(for: session) != nil))
                    }
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
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, session.lastContextTokens > 0 ? 2 : 6)

            if session.lastContextTokens > 0 {
                contextBar(session: session)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
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
                            Color.clear
                                .frame(height: 1)
                                .id(Self.scrollAnchorID)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .notchScrollEdgeShadow(.vertical, thickness: 12, intensity: 0.36)
                    .task(id: session.id) {
                        proxy.scrollTo(Self.scrollAnchorID, anchor: .bottom)
                    }
                    .onChange(of: session.messages.count) { _, _ in
                        withAnimation(.spring(
                            duration: NotchConstants.tabSwitchSpringDuration,
                            bounce: NotchConstants.tabSwitchSpringBounce
                        )) {
                            proxy.scrollTo(Self.scrollAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    func quickApprovalBar(session: AISessionState, ctx: PermissionContext) -> some View {
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

    func sessionRow(_ session: AISessionState) -> some View {
        let approval = approvalContext(for: session)

        return Button {
            selectedSessionId = session.id
        } label: {
            HStack(alignment: .top, spacing: 11) {
                sourceMark(session)

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
    func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, color: sourceTint(source))
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(sourceTint(source))
        case .opencode:
            OpencodeLogoIcon(size: size, color: sourceTint(source))
        case .zcode:
            ZcodeLogoIcon(size: size, color: sourceTint(source))
        }
    }

    func sourceMark(_ session: AISessionState) -> some View {
        let statusColor = dotColor(session.status)
        let active = session.status == .working || approvalContext(for: session) != nil

        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(sourceTint(session.source).opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(sourceTint(session.source).opacity(0.34), lineWidth: 0.8)
            )
            .frame(width: 34, height: 34)
            .overlay {
                sourceIcon(session.source, size: 17)
            }
            .overlay(alignment: .bottomTrailing) {
                statusDot(color: statusColor, active: active)
                    .offset(x: 3, y: 3)
            }
            .frame(width: 40, height: 40, alignment: .topLeading)
    }

    func statusDot(color: Color, active: Bool) -> some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(NotchTheme.panelBase.opacity(0.92), lineWidth: 1.5))
                .shadow(color: color.opacity(0.55), radius: 5)
        }
        .frame(width: 14, height: 14)
    }

    func sourceBadge(_ source: AISource) -> some View {
        HStack(spacing: 4) {
            sourceIcon(source, size: 10)
            Text(sourceLabel(source))
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(sourceTint(source))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(sourceTint(source).opacity(0.14))
        .clipShape(Capsule(style: .continuous))
    }

    func sourceLabel(_ source: AISource) -> String {
        switch source {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .opencode: "opencode"
        case .zcode: "zcode"
        }
    }

    func sourceShortLabel(_ source: AISource) -> String {
        switch source {
        case .claude: "C"
        case .gemini: "G"
        case .opencode: "O"
        case .zcode: "Z"
        }
    }

    func sourceTint(_ source: AISource) -> Color {
        switch source {
        case .claude: NotchTheme.accentText
        case .gemini: Color(red: 0.42, green: 0.68, blue: 1.0)
        case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
        case .zcode: Color(red: 0.11, green: 0.44, blue: 0.96)
        }
    }

    func eventTag(_ event: String) -> some View {
        let (label, color) = eventTagStyle(event)
        return Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.96))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(Capsule())
    }

    func eventTagStyle(_ event: String) -> (String, Color) {
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

    func sessionStatusPill(_ session: AISessionState) -> some View {
        let label: String = {
            if approvalContext(for: session) != nil {
                return "Approval"
            }
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

    func modelPill(_ model: String) -> some View {
        Text(model)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(NotchTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NotchTheme.surfaceEmphasis)
            .clipShape(Capsule(style: .continuous))
    }

    func toolPill(_ tool: String) -> some View {
        Text(tool)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(ToolStyle.color(tool).opacity(0.95))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ToolStyle.color(tool).opacity(0.14))
            .clipShape(Capsule(style: .continuous))
    }

    func dotColor(_ status: ClaudeStatus) -> Color {
        statusColor(status)
    }

    func statusColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .idle: NotchTheme.textTertiary
        case .working: NotchTheme.accentText
        case .waiting: NotchTheme.accent
        }
    }

    func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return String(localized: "ai.time_just_now")
        }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return String(format: String(localized: "ai.time_minutes_ago"), minutes)
        }
        return String(format: String(localized: "ai.time_hours_ago"), minutes / 60)
    }

    func approvalContext(for session: AISessionState) -> PermissionContext? {
        if case let .waitingForApproval(ctx) = session.phase {
            return ctx
        }
        return nil
    }

    func subagentTools(for message: ChatMessage, session: AISessionState) -> [SubagentToolCall]? {
        guard let toolName = message.toolName,
              ["Task", "Agent", "invoke_subagent"].contains(toolName) else { return nil }
        for (_, task) in session.subagentState.activeTasks {
            if message.id.contains(task.id) {
                return task.tools
            }
        }
        return nil
    }

    func approvalButtons(for session: AISessionState, ctx: PermissionContext) -> some View {
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

    func contextBar(session: AISessionState) -> some View {
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

    func sessionById(_ id: String) -> AISessionState? {
        aiService.store.get(id)
    }
}
