import SwiftUI

enum ProviderCardKind: Equatable {
    case ready // enabled+installed — service contributes to sessions/idle
    case install // enabled, not installed — active install CTA
    case reenable // disabled — passive re-enable CTA (handles orphan-installed case too)
}

struct AIChatTab: View {
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(AppSettings.self) var appSettings
    @State private var selectedSessionId: String?
    @State private var showContextDetail = false
    @State private var heroBreathe = false

    private static let scrollAnchorID = "ai-chat-bottom-anchor"

    private var allSessions: [AISessionState] {
        aiService.store.sortedSessions.filter { session in
            switch session.source {
            case .claude: return appSettings.claudeEnabled
            case .gemini: return appSettings.geminiEnabled
            case .opencode: return appSettings.opencodeEnabled
            case .zcode: return appSettings.zcodeEnabled
            }
        }
    }

    private var claudeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.claudeEnabled,
            installed: aiService.claudeProvider.isHookInstalled
        )
    }

    private var geminiKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.geminiEnabled,
            installed: aiService.geminiProvider.isHookInstalled
        )
    }

    private var opencodeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.opencodeEnabled,
            installed: aiService.opencodeProvider.isHookInstalled
        )
    }

    private var zcodeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.zcodeEnabled,
            installed: aiService.zcodeProvider.isHookInstalled
        )
    }

    private var hasAnyReadyProvider: Bool {
        claudeKind == .ready || geminiKind == .ready || opencodeKind == .ready || zcodeKind == .ready
    }

    private static func kind(enabled: Bool, installed: Bool) -> ProviderCardKind {
        switch (enabled, installed) {
        case (true, true): .ready
        case (true, false): .install
        case (false, _): .reenable
        }
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

    private var claudeCount: Int {
        allSessions.count(where: { $0.source == .claude })
    }

    private var geminiCount: Int {
        allSessions.count(where: { $0.source == .gemini })
    }

    private var opencodeCount: Int {
        allSessions.count(where: { $0.source == .opencode })
    }

    private var zcodeCount: Int {
        allSessions.count(where: { $0.source == .zcode })
    }

    private var hasMixedSources: Bool {
        [claudeCount, geminiCount, opencodeCount, zcodeCount].count(where: { $0 > 0 }) > 1
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
        case .opencode: "opencode"
        case .zcode: "zcode"
        case .none: "AI Sessions"
        }
    }

    private var consoleSummary: String {
        let sourceParts = hasMixedSources ? [
            claudeCount > 0 ? "Claude \(claudeCount)" : nil,
            geminiCount > 0 ? "Gemini \(geminiCount)" : nil,
            opencodeCount > 0 ? "opencode \(opencodeCount)" : nil,
            zcodeCount > 0 ? "zcode \(zcodeCount)" : nil,
        ].compactMap(\.self) : []

        let activeParts = [
            waitingCount > 0 ? "\(waitingCount) waiting" : nil,
            workingCount > 0 ? "\(workingCount) working" : nil,
            idleCount > 0 && workingCount + waitingCount == 0 ? "\(idleCount) idle" : nil,
        ].compactMap(\.self)

        let parts = sourceParts + activeParts
        if parts.isEmpty {
            return "\(allSessions.count) sessions"
        }
        return parts.joined(separator: " · ")
    }

    private var headerMeterSessions: [AISessionState] {
        Array(
            allSessions
                .sorted { $0.lastEventTime > $1.lastEventTime }
                .prefix(2)
        )
    }

    var body: some View {
        if allSessions.isEmpty {
            emptyConsole
        } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }

    // MARK: - Empty state

    private var emptyConsole: some View {
        VStack(spacing: 16) {
            emptyHero
            providerStatusList
            emptyFooter
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var emptyHero: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(heroBreathe ? 0.55 : 1.0)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        heroBreathe = true
                    }
                }
            Text(hasAnyReadyProvider ? "ai.empty.title_ready" : "ai.empty.title_setup")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(hasAnyReadyProvider ? "ai.empty.subtitle_ready" : "ai.empty.subtitle_setup")
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var providerStatusList: some View {
        VStack(spacing: 0) {
            providerStatusRow(source: .claude, name: "Claude Code", kind: claudeKind) {
                appSettings.claudeEnabled = true
                if !aiService.claudeProvider.isHookInstalled {
                    aiService.claudeProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .gemini, name: "Gemini CLI", kind: geminiKind) {
                appSettings.geminiEnabled = true
                if !aiService.geminiProvider.isHookInstalled {
                    aiService.geminiProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .opencode, name: "opencode", kind: opencodeKind) {
                appSettings.opencodeEnabled = true
                if !aiService.opencodeProvider.isHookInstalled {
                    aiService.opencodeProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .zcode, name: "zcode", kind: zcodeKind) {
                appSettings.zcodeEnabled = true
                if !aiService.zcodeProvider.isHookInstalled {
                    aiService.zcodeProvider.installHooks()
                }
            }
        }
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }

    @ViewBuilder
    private func providerStatusRow(
        source: AISource,
        name: String,
        kind: ProviderCardKind,
        onAction: @escaping () -> Void
    ) -> some View {
        let isPassive = kind == .reenable
        HStack(spacing: 10) {
            sourceIcon(source, size: 16)
                .opacity(isPassive ? 0.6 : 1.0)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPassive ? NotchTheme.textSecondary : NotchTheme.textPrimary)
            Spacer(minLength: 8)
            switch kind {
            case .ready:
                HStack(spacing: 5) {
                    Circle()
                        .fill(sourceTint(source))
                        .frame(width: 6, height: 6)
                    Text("ai.ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
            case .install:
                Button(action: onAction) {
                    Text("ai.install_hooks")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(NotchTheme.accent.opacity(0.18)))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            case .reenable:
                Button(action: onAction) {
                    Text("ai.enable")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var emptyFooter: some View {
        VStack(spacing: 6) {
            if hasAnyReadyProvider {
                Text("ai.empty.run_hint")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            serverStatus
        }
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
            // Title absorbs the slack and truncates first; the fixed-width summary
            // cards keep their intrinsic size instead of being compressed (their
            // meter bars can't shrink) and clipped by the notch mask.
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 8) {
                contextSummaryCard
                UsageQuotaCompactView()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Summary cards (context · usage quota)

    /// Compact card pair living in the header's top-right: session context on
    /// the left, periodic-token usage quota on the right. Each is tappable for a
    /// detail popover.
    private var contextSummaryCard: some View {
        Button { showContextDetail.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("ai.context")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                if headerMeterSessions.isEmpty {
                    serverStatus
                } else {
                    ForEach(headerMeterSessions) { session in
                        compactContextMeter(session)
                    }
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchCard(radius: 10, fill: NotchTheme.surfaceSubtle)
        .popover(isPresented: $showContextDetail, arrowEdge: .bottom) {
            contextDetailPopover
                .frame(width: 280)
        }
    }

    private var contextDetailPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ai.context")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(allSessions) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                sourceIcon(session.source, size: 11)
                                Text(session.displayTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(NotchTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let model = session.displayModel {
                                    Text(model)
                                        .font(.system(size: 9))
                                        .foregroundStyle(NotchTheme.textTertiary)
                                }
                            }
                            contextBar(session: session)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(10)
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
                        Image(systemName: "sparkles")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    case .opencode:
                        OpencodeLogoIcon(size: 22, color: .white)
                    case .zcode:
                        ZcodeLogoIcon(size: 22, color: .white)
                    }
                } else {
                    HStack(spacing: 0) {
                        ClaudeCrabIcon(size: 18, color: .white)
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .shadow(color: NotchTheme.accent.opacity(0.32), radius: 16, y: 8)
    }

    private func compactContextMeter(_ session: AISessionState) -> some View {
        HStack(spacing: 5) {
            Text(meterLabel(for: session))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 40, alignment: .trailing)
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
            .frame(width: 40, height: 6)

            Text(String(format: "%.0f%%", session.contextPercent * 100))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(NotchTheme.accentText)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func meterLabel(for session: AISessionState) -> String {
        let source = sourceShortLabel(session.source)
        let duration = sessionDurationText(session.sessionStart)
        return "\(source) \(duration)"
    }

    private func sessionDurationText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int(minutes / 60)
        if hours < 24 { return "\(hours)h" }
        let days = Int(hours / 24)
        return "\(days)d"
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
    private func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
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

    private func sourceMark(_ session: AISessionState) -> some View {
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

    private func statusDot(color: Color, active: Bool) -> some View {
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

    private func sourceBadge(_ source: AISource) -> some View {
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

    private func sourceLabel(_ source: AISource) -> String {
        switch source {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .opencode: "opencode"
        case .zcode: "zcode"
        }
    }

    private func sourceShortLabel(_ source: AISource) -> String {
        switch source {
        case .claude: "C"
        case .gemini: "G"
        case .opencode: "O"
        case .zcode: "Z"
        }
    }

    private func sourceTint(_ source: AISource) -> Color {
        switch source {
        case .claude: NotchTheme.accentText
        case .gemini: Color(red: 0.42, green: 0.68, blue: 1.0)
        case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
        case .zcode: Color(red: 0.11, green: 0.44, blue: 0.96)
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
