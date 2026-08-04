import SwiftUI

/// The floating AI-status button. Collapsed = a draggable capsule showing the
/// count of running sessions; expanded = a list+detail panel (added in Task 7).
/// Reads `AISessionStore` and the controller from the environment.
struct AIStatusFABView: View {
    @Environment(AISessionStore.self) var store
    @Environment(\.aiStatusController) var controller

    var body: some View {
        capsule
    }

    private var workingCount: Int {
        store.sortedSessions.filter { $0.status == .working }.count
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        center: .center, startRadius: 0, endRadius: 8
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: NotchTheme.accent.opacity(0.7), radius: 6)
                .modifier(PulseModifier(isActive: true))
            Text("\(workingCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.textPrimary)
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .contentShape(Capsule())
        .onTapGesture { controller?.toggleExpanded() }
    }
}
