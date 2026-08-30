import SwiftUI

/// Merged root for the single "AI" chin tab: a segmented control switches
/// between the CLI session list (`AIChatTab`) and the OpenClaw/Hermes agent
/// monitor (`AgentMonitorTab`). The two segments mount conditionally — the
/// inactive one must unmount entirely, never hide behind opacity (a hidden
///-but-mounted tree keeps doing render work; see CLAUDE.md CPU discipline).
struct AIAgentTabRoot: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case sessions
        case agents

        var id: String { rawValue }
    }

    @State private var scope: Scope = .sessions

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $scope) {
                Text("models.tab.ai").tag(Scope.sessions)
                Text("models.tab.agents").tag(Scope.agents)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 4)

            switch scope {
            case .sessions:
                AIChatTab()
            case .agents:
                AgentMonitorTab()
            }
        }
    }
}
