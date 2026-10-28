import SwiftUI

/// Formats a completion duration: <60s → "42s", <1h → "2m 14s", else "1h 5m".
private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 {
        return "\(s)s"
    }
    let (m, rs) = (s / 60, s % 60)
    if m < 60 {
        return "\(m)m \(rs)s"
    }
    let (h, rm) = (m / 60, m % 60)
    return "\(h)h \(rm)m"
}

/// One completion card in the toast row under the notch: notch-black with a
/// rotating color ring (so it reads against a black wallpaper too), the
/// source app's logo, the task title and a tool·model·tokens·duration line,
/// and a close glyph in the top-trailing corner. Fixed size from
/// `CompletionToastLayout` — the panel resolves clicks (close) from that
/// same geometry, so nothing here is a SwiftUI button.
struct CompletionToastView: View {
    let item: CompletionItem

    var body: some View {
        HStack(spacing: 10) {
            sourceIcon(item.source)
                .frame(
                    width: NotchConstants.completionToastIconSize + 4,
                    height: NotchConstants.completionToastIconSize + 4
                )

            VStack(alignment: .leading, spacing: 2) {
                // Prefer the task title (firstUserMessage-derived); fall back to name.
                Text(item.subtitle ?? item.name)
                    .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail = detailLine(for: item) {
                    Text(detail)
                        .font(.system(size: NotchConstants.completionToastFontSize - 2, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        // Keep text clear of the close glyph's hit square.
        .padding(.trailing, CompletionToastLayout.closeSize + CompletionToastLayout.closeInset + 2)
        .frame(width: CompletionToastLayout.cardWidth, height: CompletionToastLayout.cardHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(CompletionToastRing(cornerRadius: Self.cornerRadius))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: CompletionToastLayout.closeSize, height: CompletionToastLayout.closeSize)
                .padding(CompletionToastLayout.closeInset)
        }
    }

    private static let cornerRadius: CGFloat = 14

    /// "tool · model · tokens · duration" for the single-item detail line,
    /// skipping nil fields. Returns nil when there is no detail at all.
    private func detailLine(for item: CompletionItem) -> String? {
        var parts: [String] = []
        if let tool = item.tool, !tool.isEmpty {
            parts.append(tool)
        }
        if let model = item.model {
            parts.append(model)
        }
        if let tokens = item.tokenDisplay {
            parts.append(tokens)
        }
        if let duration = item.duration {
            parts.append(formatDuration(duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The leading brand mark for the completion's source. Mirrors
    /// `AIChatTab.sourceIcon` for the AI cases.
    @ViewBuilder
    private func sourceIcon(_ source: CompletionSource) -> some View {
        let s = NotchConstants.completionToastIconSize
        switch source {
        case .ai(.claude):
            ClaudeCrabIcon(size: s, color: Color(red: 0.85, green: 0.47, blue: 0.34))
        case .ai(.gemini):
            Image(systemName: "sparkles")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.55, blue: 0.95))
        case .ai(.opencode):
            OpencodeLogoIcon(size: s, color: .white)
        case .ai(.zcode):
            ZcodeLogoIcon(size: s, color: Color(red: 0.11, green: 0.44, blue: 0.96))
        case .agent:
            Image(systemName: "cpu")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        case .pomodoro:
            Image(systemName: "timer")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        }
    }
}

/// The card's border: a multi-color conic gradient that slowly rotates, seen
/// through a 1.5pt rounded-rect stroke mask. Turned by Core Animation (the
/// `EdgeBarSpinningArc` pattern), not SwiftUI: a `TimelineView` ring measured
/// 12–18% of a core for four cards (isolated bench, 20s × 3), the CA version
/// leaves the app process ~idle — the turn runs in the render server. No
/// rotation under Reduce Motion (the colored ring still shows). Torn down
/// with the panel whenever the row is empty or off-screen.
private struct CompletionToastRing: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> CompletionToastRingView {
        CompletionToastRingView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ view: CompletionToastRingView, context: Context) {}
}

final class CompletionToastRingView: NSView {
    static let lineWidth: CGFloat = 1.5
    /// Seconds per full turn.
    static let period: CFTimeInterval = 4
    private static let key = "turn"
    private static let colors: [NSColor] = [
        NSColor(NotchTheme.accent),
        NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1),
        NSColor(red: 0.62, green: 0.42, blue: 1.0, alpha: 1),
        NSColor(red: 0.25, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(red: 0.2, green: 0.86, blue: 0.78, alpha: 1),
        NSColor(NotchTheme.accent),
    ]

    private let cornerRadius: CGFloat
    private let gradient = CAGradientLayer()
    private let strokeMask = CAShapeLayer()

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = Self.colors.map(\.cgColor)
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.black.cgColor
        strokeMask.lineWidth = Self.lineWidth
        layer?.addSublayer(gradient)
        layer?.mask = strokeMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    /// Never a click target: the toast host resolves clicks from geometry.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A square as wide as the card's diagonal, so the rotating gradient
        // always covers every corner of the stroke.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        strokeMask.frame = bounds
        let inset = Self.lineWidth / 2
        strokeMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: cornerRadius - inset,
            cornerHeight: cornerRadius - inset,
            transform: nil
        )
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        gradient.contentsScale = window.backingScaleFactor
        strokeMask.contentsScale = window.backingScaleFactor
        guard gradient.animation(forKey: Self.key) == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = (layer?.contentsAreFlipped() ?? false) ? 2 * Double.pi : -2 * Double.pi
        turn.duration = Self.period
        turn.repeatCount = .infinity
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        turn.isRemovedOnCompletion = false
        gradient.add(turn, forKey: Self.key)
    }
}
