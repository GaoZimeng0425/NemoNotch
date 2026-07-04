import SwiftUI

@MainActor
@Observable
final class BadgeViewModel {
    private let mediaService: MediaService
    private let calendarService: CalendarService
    private let aiService: AICLIMonitorService
    private let notificationService: NotificationService
    private let agentRegistry: AgentMonitorRegistry
    private let pomodoroService: PomodoroTimerService
    private let appSettings: AppSettings

    var shownHasActiveBadge: Bool = false
    var displayedBadgeItems: [BadgeItem] = []
    private var badgeTypeUpdateTask: Task<Void, Never>?
    private var wasWaitingForApproval = false

    init(
        mediaService: MediaService,
        calendarService: CalendarService,
        aiService: AICLIMonitorService,
        notificationService: NotificationService,
        agentRegistry: AgentMonitorRegistry,
        pomodoroService: PomodoroTimerService,
        appSettings: AppSettings
    ) {
        self.mediaService = mediaService
        self.calendarService = calendarService
        self.aiService = aiService
        self.notificationService = notificationService
        self.agentRegistry = agentRegistry
        self.pomodoroService = pomodoroService
        self.appSettings = appSettings
    }

    // MARK: - Computed

    var activeBadgeItems: [BadgeItem] {
        var items: [BadgeItem] = []

        let activeSessions = aiService.store.sortedSessions.filter { session in
            let providerEnabled: Bool = switch session.source {
            case .claude: appSettings.claudeEnabled
            case .gemini: appSettings.geminiEnabled
            case .opencode: appSettings.opencodeEnabled
            }
            return providerEnabled && (session.phase.isActive || session.phase.needsAttention)
        }

        for session in activeSessions {
            if session.phase.isWaitingForApproval {
                items.append(.ai(
                    source: session.source,
                    status: .waiting,
                    tool: session.phase.approvalToolName,
                    waitingApproval: true,
                    sessionID: session.id
                ))
            }
        }

        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            items.append(.notification(bundleID: top.bundleID, count: top.count))
        }

        if pomodoroService.state.isActive {
            items.append(.pomodoro(phase: pomodoroService.currentPhase))
        }

        for agent in agentRegistry.activeAgents {
            items.append(.agents(agentID: agent.id, state: agent.state, emoji: agent.emoji))
        }

        for session in activeSessions {
            if !session.phase.isWaitingForApproval, session.status == .working {
                items.append(.ai(
                    source: session.source,
                    status: session.status,
                    tool: session.currentTool,
                    waitingApproval: false,
                    sessionID: session.id
                ))
            }
        }

        if mediaService.playbackState.isPlaying { items.append(.media) }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < NotchConstants.upcomingEventThresholdMinutes { items.append(.calendar) }
        }
        return items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
    }

    var hasActiveBadge: Bool {
        !activeBadgeItems.isEmpty
    }

    /// Display-ready grouped/capped layout for the collapsed compact badges.
    var badgeCluster: BadgeCluster {
        BadgeGrouping.cluster(displayedBadgeItems, cap: NotchConstants.badgeGroupCap)
    }

    /// Activity glow for the expanded notch: amber while a session awaits
    /// approval, green while AI is working or an agent is active, otherwise off.
    var glowState: NotchGlow {
        BadgeItem.glow(for: activeBadgeItems)
    }

    // MARK: - Lifecycle

    func initialize() {
        shownHasActiveBadge = hasActiveBadge
        displayedBadgeItems = activeBadgeItems
        wasWaitingForApproval = aiService.activeSession?.phase.isWaitingForApproval == true
    }

    /// Apply a new badge set, animating `displayedBadgeItems` and
    /// `shownHasActiveBadge` together so the compact-badge layout stays in sync.
    ///
    /// Non-empty updates coalesce on a 16ms tick (unchanged). An update that
    /// drops to *empty* is delayed by `badgeEmptyGrace`: if a non-empty set
    /// arrives within that window the pending collapse is cancelled, so a
    /// momentary idle dip (e.g. an agent briefly returning to .idle between
    /// tool calls) no longer flips `shownHasActiveBadge` false→true and replays
    /// the right-edge badge's slide/spread animation.
    func applyBadgeUpdate(newTypes: [BadgeItem]) {
        badgeTypeUpdateTask?.cancel()
        let isEmpty = newTypes.isEmpty
        let delay: Duration = isEmpty ? NotchConstants.badgeEmptyGrace : .milliseconds(16)
        badgeTypeUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(
                duration: NotchConstants.badgeSpringDuration,
                bounce: NotchConstants.badgeSpringBounce
            )) {
                displayedBadgeItems = newTypes
                shownHasActiveBadge = !isEmpty
            }
        }
    }

    func checkApprovalSound(isOpen: Bool) {
        let isWaiting = aiService.activeSession?.phase.isWaitingForApproval == true
        if isWaiting, !wasWaitingForApproval, !TerminalDetector.isTerminalFrontmost, !isOpen {
            NSSound(named: "Pop")?.play()
        }
        wasWaitingForApproval = isWaiting
    }
}
