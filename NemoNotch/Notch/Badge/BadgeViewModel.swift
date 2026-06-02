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

    var hasMultipleBadges: Bool {
        displayedBadgeItems.count >= 2
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

    func updateDisplayedBadges(newTypes: [BadgeItem]) {
        badgeTypeUpdateTask?.cancel()
        badgeTypeUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(
                duration: NotchConstants.badgeSpringDuration,
                bounce: NotchConstants.badgeSpringBounce
            )) {
                displayedBadgeItems = newTypes
            }
        }
    }

    func updateHasActiveBadge(_ newValue: Bool) {
        withAnimation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)) {
            shownHasActiveBadge = newValue
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
