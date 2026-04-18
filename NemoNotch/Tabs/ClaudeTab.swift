import SwiftUI

struct ClaudeTab: View {
    let claudeService: ClaudeCodeService

    var body: some View {
        if !claudeService.isHookInstalled {
            installPrompt
        } else if claudeService.sessions.isEmpty {
            idleState
        } else {
            sessionList
        }
    }

    private var installPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("Claude Code Hooks 未安装")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Button("安装 Hooks") {
                claudeService.installHooks()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("无活跃会话")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(claudeService.sessions.values.sorted { $0.lastEventTime > $1.lastEventTime })) { session in
                        sessionRow(session)
                    }
                }
            }

            Button {
                claudeService.uninstallHooks()
            } label: {
                Text("卸载 Hooks")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func sessionRow(_ session: ClaudeState) -> some View {
        HStack(spacing: 8) {
            statusDot(session.status)

            VStack(alignment: .leading, spacing: 2) {
                if let tool = session.currentTool {
                    Text(tool)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    Text("空闲")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(timeAgo(session.lastEventTime))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func statusDot(_ status: ClaudeStatus) -> some View {
        Circle()
            .fill(dotColor(status))
            .frame(width: 8, height: 8)
            .modifier(PulseModifier(isActive: status == .working))
    }

    private func dotColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .idle: .gray
        case .working: .green
        case .waiting: .yellow
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }
}

struct PulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isActive
            )
    }
}
