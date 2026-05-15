import SwiftUI

struct MenuBarLabel: View {
    @Environment(AICLIMonitorService.self) private var aiService
    @Environment(AgentMonitorRegistry.self) private var agentRegistry
    @Environment(MediaService.self) private var mediaService

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        let sessions = aiService.store.sortedSessions
        if sessions.contains(where: \.phase.isWaitingForApproval) {
            return "exclamationmark.bubble.fill"
        }
        if agentRegistry.hasAnyActiveAgent {
            return "ant.fill"
        }
        if sessions.contains(where: { $0.status == .working }) {
            return "sparkle"
        }
        if mediaService.playbackState.isPlaying {
            return "play.circle.fill"
        }
        return "menubar.rectangle"
    }
}
