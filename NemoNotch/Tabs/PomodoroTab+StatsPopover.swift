import SwiftUI

struct PomodoroStatsPopover: View {
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(TaskStore.self) var taskStore

    var body: some View {
        let stats = PomodoroStats(history: historyStore)
        VStack(alignment: .leading, spacing: 12) {
            countsSection(title: String(localized: "pomodoro.stats.today"), counts: stats.today())
            Divider()
            countsSection(title: String(localized: "pomodoro.stats.week"), counts: stats.week())
            Divider()
            allTimeSection(stats: stats)
            Divider()
            recentSection(stats: stats)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func countsSection(title: String, counts: PomodoroStats.Counts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                Text("✓ \(counts.completed)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("~ \(counts.partial)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("✗ \(counts.abandoned)")
            }
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func allTimeSection(stats: PomodoroStats) -> some View {
        let all = stats.allTime()
        VStack(alignment: .leading, spacing: 2) {
            Text("pomodoro.stats.all")
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                Text("✓ \(all.completed)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("~ \(all.partial)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("✗ \(all.abandoned)")
            }
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
            if let freq = stats.mostFrequentTaskID(),
               let task = taskStore.tasks.first(where: { $0.id == freq.taskID }) {
                Text(String(
                    format: String(localized: "pomodoro.stats.mostFrequent"),
                    task.title,
                    freq.count
                ))
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func recentSection(stats: PomodoroStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("pomodoro.stats.recent")
                .font(.system(size: 11, weight: .semibold))
            ForEach(stats.recent(limit: 5)) { r in
                recentRow(r)
            }
        }
    }

    private func recentRow(_ r: PomodoroRecord) -> some View {
        HStack(spacing: 6) {
            Text(r.endedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
            Text(taskTitle(for: r))
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(outcomeLabel(r))
                .font(.system(size: 10))
                .foregroundStyle(outcomeColor(r.outcome))
        }
    }

    private func taskTitle(for r: PomodoroRecord) -> String {
        if let id = r.taskID, let t = taskStore.tasks.first(where: { $0.id == id }) {
            return t.title
        }
        return "—"
    }

    private func outcomeLabel(_ r: PomodoroRecord) -> String {
        let minutes = Int(r.actualDuration / 60)
        switch r.outcome {
        case .completed: return "\(minutes)✓"
        case .partial: return "partial \(minutes)"
        case .abandoned: return "✗"
        }
    }

    private func outcomeColor(_ o: PomodoroRecord.Outcome) -> Color {
        switch o {
        case .completed: return NotchTheme.accent
        case .partial: return Color.orange.opacity(0.9)
        case .abandoned: return NotchTheme.textTertiary
        }
    }
}
