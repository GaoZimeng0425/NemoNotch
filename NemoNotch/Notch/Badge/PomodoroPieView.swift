import SwiftUI

enum PomodoroPieStyle {
    case badge // 14pt; thin background ring
    case row // 12pt; same look as badge, smaller
    case compact // 22pt; inline use in the active row
}

struct PomodoroPieView: View {
    let remainingFraction: Double // 0...1, clamped
    let phase: PomodoroPhase
    let style: PomodoroPieStyle

    private var size: CGFloat {
        switch style {
        case .badge: return 14
        case .row: return 12
        case .compact: return 22
        }
    }

    private var ringLineWidth: CGFloat {
        switch style {
        case .badge, .row: return 2
        case .compact: return 3
        }
    }

    private var color: Color {
        switch phase {
        case .work:
            return Color(red: 0.93, green: 0.36, blue: 0.36)
        case .shortBreak:
            return Color(red: 0.34, green: 0.78, blue: 0.51)
        case .longBreak:
            return Color(red: 0.40, green: 0.66, blue: 0.92)
        case .idle:
            return NotchTheme.textTertiary
        }
    }

    private var clamped: Double {
        max(0, min(1, remainingFraction))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: ringLineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
