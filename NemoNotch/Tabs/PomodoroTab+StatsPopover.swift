import SwiftUI

struct PomodoroStatsPopover: View {
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(TaskStore.self) var taskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stats — coming soon (Task 34)")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}
