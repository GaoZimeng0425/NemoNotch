import SwiftUI

enum PomodoroPieStyle {
    case badge // 14pt; thin background ring
    case row // 12pt; same look as badge, smaller
    case large // 88pt; thicker background ring, optional center text
}

struct PomodoroPieView: View {
    let remainingFraction: Double // 0...1, clamped
    let phase: PomodoroPhase
    let style: PomodoroPieStyle
    var centerText: String?

    private var size: CGFloat {
        switch style {
        case .badge: return 14
        case .row: return 12
        case .large: return 88
        }
    }

    private var ringLineWidth: CGFloat {
        switch style {
        case .badge, .row: return 1
        case .large: return 2.5
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

            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                Path { p in
                    p.move(to: center)
                    p.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * clamped),
                        clockwise: false
                    )
                    p.closeSubpath()
                }
                .fill(color)
            }

            if let centerText, style == .large {
                Text(centerText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(NotchTheme.textPrimary)
            }
        }
        .frame(width: size, height: size)
    }
}
