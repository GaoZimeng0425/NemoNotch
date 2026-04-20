import SwiftUI

struct OpenClawTab: View {
    @Environment(OpenClawService.self) var openClawService

    var body: some View {
        if !openClawService.isInstalled {
            notInstalled
        } else if !openClawService.gatewayOnline {
            offlineState
        } else if openClawService.agents.isEmpty {
            idleState
        } else {
            agentList
        }
    }

    // MARK: - Not Installed

    private var notInstalled: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("OpenClaw 未安装")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Text("npm install -g openclaw@latest")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Gateway Offline

    private var offlineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("Gateway 离线")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("等待连接...")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Idle (no agents)

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("所有 Agent 空闲")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Gateway 在线")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Agent List

    private var agentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let (active, idle) = partitionedAgents

                ForEach(active) { agent in
                    agentRow(agent)
                }

                if !active.isEmpty && !idle.isEmpty {
                    Divider()
                        .background(.white.opacity(0.1))
                        .padding(.vertical, 4)
                }

                ForEach(idle) { agent in
                    agentRow(agent)
                        .opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var partitionedAgents: (active: [AgentInfo], idle: [AgentInfo]) {
        let sorted = openClawService.agents.values.sorted { $0.lastEventTime > $1.lastEventTime }
        let active = sorted.filter { $0.state != .idle }
        let idle = sorted.filter { $0.state == .idle }
        return (active, idle)
    }

    // MARK: - Agent Row

    private func agentRow(_ agent: AgentInfo) -> some View {
        HStack(spacing: 8) {
            Text(agent.emoji)
                .font(.system(size: 16))
                .frame(width: 20)
                .modifier(PulseModifier(isActive: agent.state == .working || agent.state == .toolCalling))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    stateTag(agent.state)
                }

                if let tool = agent.currentTool, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                if let msg = agent.lastMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let workspace = agent.workspace {
                        Text(URL(fileURLWithPath: workspace).lastPathComponent)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                    Text(timeAgo(agent.lastEventTime))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - State Tag

    private func stateTag(_ state: AgentState) -> some View {
        Text(stateLabel(state))
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(stateColor(state).opacity(0.7))
            .clipShape(Capsule())
    }

    private func stateLabel(_ state: AgentState) -> String {
        switch state {
        case .idle: return "空闲"
        case .working: return "工作中"
        case .speaking: return "发言"
        case .toolCalling: return "工具调用"
        case .error: return "错误"
        }
    }

    private func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return .gray
        case .working: return .blue
        case .speaking: return .green
        case .toolCalling: return .orange
        case .error: return .red
        }
    }

    // MARK: - Helpers

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)分钟前" }
        return "\(minutes / 60)小时前"
    }
}
