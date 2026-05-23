import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        VStack {
            Text("Pomodoro Tab — coming soon")
                .font(.system(size: 13))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
