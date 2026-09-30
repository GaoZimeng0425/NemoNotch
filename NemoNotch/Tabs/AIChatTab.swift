import SwiftUI

enum ProviderCardKind: Equatable {
    case ready // enabled+installed — service contributes to sessions/idle
    case install // enabled, not installed — active install CTA
    case reenable // disabled — passive re-enable CTA (handles orphan-installed case too)
}

struct AIChatTab: View {
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(AppSettings.self) var appSettings
    @Environment(AgentMonitorRegistry.self) var agentRegistry
    @Environment(OpenClawService.self) var openClaw
    @Environment(HermesService.self) var hermesService
    @State var selectedSessionId: String?
    @State var showContextDetail = false
    @State var expandedAgentId: String?

    static let scrollAnchorID = "ai-chat-bottom-anchor"

    var allSessions: [AISessionState] {
        aiService.store.sortedSessions.filter { session in
            switch session.source {
            case .claude: return appSettings.claudeEnabled
            case .gemini: return appSettings.geminiEnabled
            case .opencode: return appSettings.opencodeEnabled
            case .zcode: return appSettings.zcodeEnabled
            }
        }
    }

    // MARK: - Merged agent entries

    /// One agent from an online monitor, bundled with everything its row
    /// needs (source style + optional message log for expansion).
    struct AgentEntry {
        let agent: MonitoredAgent
        let style: AgentMonitorSourceStyle
        let messages: [ChatMessage]?
    }

    /// Agents from online installed monitors — active and idle alike, exactly
    /// like sessions — that merge into the unified console list.
    var agentEntries: [AgentEntry] {
        agentRegistry.installedMonitors
            .filter(\.isOnline)
            .flatMap { monitor -> [AgentEntry] in
                let style = AgentMonitorSourceStyle(
                    displayName: monitor.displayName,
                    iconEmoji: monitor.iconEmoji,
                    iconAssetName: monitor.iconAssetName
                )
                return monitor.agents.values
                    .sorted { $0.lastEventTime > $1.lastEventTime }
                    .map { AgentEntry(agent: $0, style: style, messages: monitor.sessionMessages[$0.id]) }
            }
            .sorted { $0.agent.lastEventTime > $1.agent.lastEventTime }
    }

    /// Sessions and agents in one recency-sorted list — the merged console.
    enum ConsoleItem: Identifiable {
        case session(AISessionState)
        case agent(AgentEntry)

        var id: String {
            switch self {
            case let .session(session): "s-\(session.id)"
            case let .agent(entry): "a-\(entry.agent.id)"
            }
        }

        var sortTime: Date {
            switch self {
            case let .session(session): session.lastEventTime
            case let .agent(entry): entry.agent.lastEventTime
            }
        }
    }

    var consoleItems: [ConsoleItem] {
        (allSessions.map(ConsoleItem.session) + agentEntries.map(ConsoleItem.agent))
            .sorted { $0.sortTime > $1.sortTime }
    }

    /// "OpenClaw 2" style summary parts for online monitors with non-idle agents.
    var agentSourceParts: [String] {
        agentRegistry.installedMonitors
            .filter { $0.isOnline && $0.agents.values.contains { $0.state != .idle } }
            .map { monitor in
                let label = AgentMonitorSourceStyle(
                    displayName: monitor.displayName,
                    iconEmoji: monitor.iconEmoji,
                    iconAssetName: monitor.iconAssetName
                ).label
                let count = monitor.agents.values.count { $0.state != .idle }
                return "\(label) \(count)"
            }
    }

    var agentWorkingCount: Int {
        agentRegistry.installedMonitors
            .flatMap(\.agents.values)
            .count { $0.state == .working || $0.state == .toolCalling }
    }

    var claudeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.claudeEnabled,
            installed: aiService.claudeProvider.isHookInstalled
        )
    }

    var geminiKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.geminiEnabled,
            installed: aiService.geminiProvider.isHookInstalled
        )
    }

    var opencodeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.opencodeEnabled,
            installed: aiService.opencodeProvider.isHookInstalled
        )
    }

    var zcodeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.zcodeEnabled,
            installed: aiService.zcodeProvider.isHookInstalled
        )
    }

    var hasAnyReadyProvider: Bool {
        claudeKind == .ready || geminiKind == .ready || opencodeKind == .ready || zcodeKind == .ready
    }

    private static func kind(enabled: Bool, installed: Bool) -> ProviderCardKind {
        switch (enabled, installed) {
        case (true, true): .ready
        case (true, false): .install
        case (false, _): .reenable
        }
    }

    var workingCount: Int {
        allSessions.count(where: { $0.status == .working })
    }

    var waitingCount: Int {
        allSessions.count(where: { $0.status == .waiting })
    }

    var idleCount: Int {
        allSessions.count(where: { $0.status == .idle })
    }

    var claudeCount: Int {
        allSessions.count(where: { $0.source == .claude })
    }

    var geminiCount: Int {
        allSessions.count(where: { $0.source == .gemini })
    }

    var opencodeCount: Int {
        allSessions.count(where: { $0.source == .opencode })
    }

    var zcodeCount: Int {
        allSessions.count(where: { $0.source == .zcode })
    }

    var hasMixedSources: Bool {
        [claudeCount, geminiCount, opencodeCount, zcodeCount].count(where: { $0 > 0 }) > 1
    }

    var dominantSource: AISource? {
        guard let first = allSessions.first?.source,
              allSessions.allSatisfy({ $0.source == first }) else {
            return nil
        }
        return first
    }

    var consoleTitle: String {
        switch dominantSource {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .opencode: "opencode"
        case .zcode: "zcode"
        case .none: "AI Sessions"
        }
    }

    var consoleSummary: String {
        let agentParts = agentSourceParts
        if allSessions.isEmpty, agentParts.isEmpty {
            return String(localized: hasAnyReadyProvider ? "ai.empty.subtitle_ready" : "ai.empty.subtitle_setup")
        }

        let sourceParts = hasMixedSources ? [
            claudeCount > 0 ? "Claude \(claudeCount)" : nil,
            geminiCount > 0 ? "Gemini \(geminiCount)" : nil,
            opencodeCount > 0 ? "opencode \(opencodeCount)" : nil,
            zcodeCount > 0 ? "zcode \(zcodeCount)" : nil,
        ].compactMap(\.self) : []

        let agentWorking = agentWorkingCount
        let activeParts = [
            waitingCount > 0 ? "\(waitingCount) waiting" : nil,
            workingCount + agentWorking > 0 ? "\(workingCount + agentWorking) working" : nil,
            idleCount > 0 && workingCount + waitingCount + agentWorking == 0 ? "\(idleCount) idle" : nil,
        ].compactMap(\.self)

        let parts = sourceParts + agentParts + activeParts
        if parts.isEmpty {
            return "\(allSessions.count) sessions"
        }
        return parts.joined(separator: " · ")
    }

    var headerMeterSessions: [AISessionState] {
        Array(
            allSessions
                .sorted { $0.lastEventTime > $1.lastEventTime }
                .prefix(2)
        )
    }

    var body: some View {
        if let sessionId = selectedSessionId,
           let session = sessionById(sessionId),
           allSessions.contains(where: { $0.id == sessionId }) {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }

    var sessionList: some View {
        VStack(spacing: 12) {
            aiConsoleHeader

            ScrollView(.vertical, showsIndicators: false) {
                if consoleItems.isEmpty, openClaw.pendingApproval == nil {
                    setupList
                } else {
                    LazyVStack(spacing: 8) {
                        if openClaw.pendingApproval != nil {
                            OpenClawApprovalBanner()
                        }
                        ForEach(consoleItems) { item in
                            switch item {
                            case let .session(session):
                                sessionRow(session)
                            case let .agent(entry):
                                agentRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .notchScrollEdgeShadow(.vertical, thickness: 16, intensity: 0.30)
        }
        .padding(.horizontal, 2)
    }

    func agentRow(_ entry: AgentEntry) -> some View {
        AgentRowView(
            agent: entry.agent,
            sourceStyle: entry.style,
            isExpanded: expandedAgentId == entry.agent.id,
            messages: entry.messages
        )
        .onTapGesture {
            guard entry.messages != nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedAgentId = expandedAgentId == entry.agent.id ? nil : entry.agent.id
            }
        }
    }

    var aiConsoleHeader: some View {
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
}
