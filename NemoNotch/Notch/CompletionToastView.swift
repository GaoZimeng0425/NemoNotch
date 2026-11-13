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
/// source app's logo, the task title, a tool·model·tokens·duration line and
/// the working directory (AI sessions), and a close glyph in the top-trailing
/// corner. Fixed size from
/// `CompletionToastLayout` — the panel resolves clicks (close) from that
/// same geometry, so nothing here is a SwiftUI button.
struct CompletionToastView: View {
    let item: CompletionItem
    /// When the card last arrived, shown as "5 seconds ago" in the title row.
    let shownAt: Date

    var body: some View {
        HStack(spacing: 10) {
            sourceIcon(item.source)
                .frame(
                    width: NotchConstants.completionToastIconSize + 4,
                    height: NotchConstants.completionToastIconSize + 4
                )

            if let notice = item.notice {
                noticeText(notice)
            } else if let external = item.external {
                externalText(external)
            } else if let calendar = item.calendar {
                calendarText(calendar)
            } else {
                completionText
            }
        }
        .padding(.leading, 14)
        // Keep text clear of the close glyph's hit square.
        .padding(.trailing, CompletionToastLayout.closeSize + CompletionToastLayout.closeInset + 2)
        .frame(width: CompletionToastLayout.cardWidth, height: CompletionToastLayout.cardHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // The ring speaks the tone (spec: color = why you're needed); cards
        // with no lifecycle keep the rainbow.
        .overlay(CompletionToastRing(cornerRadius: Self.cornerRadius, colors: item.kind?.tone.ring))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: CompletionToastLayout.closeSize, height: CompletionToastLayout.closeSize)
                .padding(CompletionToastLayout.closeInset)
        }
    }

    private static let cornerRadius: CGFloat = 14

    /// A card's first line: its title, truncated first, then how long ago the
    /// card arrived ("5 seconds ago"). The system re-renders the relative
    /// time itself — no timer of ours drives it.
    private func titleRow(@ViewBuilder _ title: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title()
            Spacer(minLength: 0)
            Text(.currentDate, format: .reference(
                to: shownAt,
                allowedFields: [.second, .minute, .hour, .day],
                maxFieldCount: 1
            ))
            .font(.system(size: NotchConstants.completionToastFontSize - 3))
            .foregroundStyle(NotchTheme.textTertiary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// Title, tool·model·tokens·duration, and working directory.
    private var completionText: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The prompt the user typed this turn; falls back to the session title / name.
            titleRow {
                Text(item.subtitle ?? item.name)
                    .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let detail = detailLine(for: item) {
                Text(detail)
                    .font(.system(size: NotchConstants.completionToastFontSize - 2, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Where it ran: `~`-folded, middle-truncated so both the root
            // and the project folder stay readable.
            if let path = CompletionPath.display(item.path) {
                Text(verbatim: path)
                    .font(.system(
                        size: NotchConstants.completionToastFontSize - 3,
                        weight: .regular,
                        design: .monospaced
                    ))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Calendar card: title, time (· place), and the link it opens on click.
    private func calendarText(_ calendar: CalendarCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow {
                Text(verbatim: item.name)
                    .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(verbatim: calendar.timeLine)
                .font(.system(size: NotchConstants.completionToastFontSize - 2, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let link = calendar.linkLabel {
                Label(link, systemImage: "link")
                    .font(.system(size: NotchConstants.completionToastFontSize - 3))
                    .foregroundStyle(NotchTheme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// External-app card: the caller's app name, then its own title and body
    /// verbatim. Mirrors `noticeText`'s three-line structure.
    private func externalText(_ external: ExternalCardContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow {
                Text(verbatim: item.name)
                    .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(verbatim: external.title)
                .font(.system(size: NotchConstants.completionToastFontSize - 2, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let body = external.body {
                Text(verbatim: body)
                    .font(.system(size: NotchConstants.completionToastFontSize - 3))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Notification card: app name (+ red count when several), then the
    /// two `NotificationCard` lines.
    private func noticeText(_ notice: NotificationCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow {
                HStack(spacing: 6) {
                    Text(verbatim: item.name)
                        .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if notice.count > 1 {
                        Text(verbatim: "\(notice.count)")
                            .font(.system(
                                size: NotchConstants.completionToastFontSize - 3,
                                weight: .bold,
                                design: .rounded
                            ))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.red))
                    }
                }
            }
            if let line1 = notice.line1 {
                Text(verbatim: line1)
                    .font(.system(size: NotchConstants.completionToastFontSize - 2, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let line2 = notice.line2 {
                Text(verbatim: line2)
                    .font(.system(size: NotchConstants.completionToastFontSize - 3))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "kind · tool · model · tokens · duration" for the single-item detail
    /// line, skipping nil fields. The kind's verb leads (等你选 ·
    /// AskUserQuestion · …) so the card says what happened even where the
    /// ring color is missed. Returns nil when there is no detail at all.
    private func detailLine(for item: CompletionItem) -> String? {
        var parts: [String] = []
        if let kind = item.kind {
            parts.append(kind.verb)
        }
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
        case let .ai(ai):
            aiIcon(ai, size: s)
        case .agent:
            Image(systemName: "cpu")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        case let .notification(bundleID):
            if let icon = AppIconCache.icon(bundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: s + 4, height: s + 4)
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: s * 0.9, weight: .semibold))
                    .foregroundStyle(NotchTheme.accent)
            }
        case let .external(icon):
            externalIcon(icon, size: s)
        }
    }

    @ViewBuilder
    private func aiIcon(_ ai: AISource, size s: CGFloat) -> some View {
        switch ai {
        case .claude:
            ClaudeCrabIcon(size: s, color: Color(red: 0.85, green: 0.47, blue: 0.34))
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.55, blue: 0.95))
        case .opencode:
            OpencodeLogoIcon(size: s, color: .white)
        case .zcode:
            ZcodeLogoIcon(size: s, color: Color(red: 0.11, green: 0.44, blue: 0.96))
        }
    }

    /// External card mark: `ai:` reuses the AI brand marks, `app:` the installed
    /// app's icon, `sf:` the symbol; anything that can't render (unknown symbol,
    /// app not installed, no icon) falls back to the generic card mark.
    @ViewBuilder
    private func externalIcon(_ icon: ExternalToastIcon?, size s: CGFloat) -> some View {
        switch icon {
        case let .ai(ai):
            aiIcon(ai, size: s)
        case let .app(bundleID):
            if let image = AppIconCache.icon(bundleID: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: s + 4, height: s + 4)
            } else {
                genericExternalIcon(size: s)
            }
        case let .symbol(symbol):
            // Probe existence: a name that isn't a real SF Symbol renders blank.
            if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol)
                    .font(.system(size: s * 0.9, weight: .semibold))
                    .foregroundStyle(NotchTheme.accent)
            } else {
                genericExternalIcon(size: s)
            }
        case nil:
            genericExternalIcon(size: s)
        }
    }

    private func genericExternalIcon(size s: CGFloat) -> some View {
        Image(systemName: "app.dashed")
            .font(.system(size: s * 0.9, weight: .semibold))
            .foregroundStyle(NotchTheme.accent)
    }
}

/// App icons for notification cards, resolved once per bundle id.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// The card's border: a multi-color conic gradient that slowly rotates, seen
/// through a 1.5pt rounded-rect stroke mask. Turned by Core Animation (the
/// `EdgeBarSpinningArc` pattern), not SwiftUI: a `TimelineView` ring measured
/// 10.5–17.9% of a core for four cards (isolated bench, 20s each, two batches:
/// 12.80/17.87/11.70 and 10.45/13.50/12.04), the CA version
/// leaves the app process ~idle — the turn runs in the render server. No
/// rotation under Reduce Motion (the colored ring still shows). Torn down
/// with the panel whenever the row is empty or off-screen.
private struct CompletionToastRing: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// The tone's ring stops; nil keeps the legacy rainbow for cards with no
    /// lifecycle (calendar / notification / external).
    let colors: [NSColor]?

    func makeNSView(context: Context) -> CompletionToastRingView {
        CompletionToastRingView(cornerRadius: cornerRadius, colors: colors)
    }

    func updateNSView(_ view: CompletionToastRingView, context: Context) {}
}

final class CompletionToastRingView: NSView {
    static let lineWidth: CGFloat = 1.5
    /// Seconds per full turn.
    static let period: CFTimeInterval = 4
    private static let key = "turn"
    /// The legacy multi-color stops — still the ring for sources with no
    /// lifecycle (calendar / notification / external cards).
    static let rainbow: [NSColor] = [
        NSColor(NotchTheme.accent),
        NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1),
        NSColor(red: 0.62, green: 0.42, blue: 1.0, alpha: 1),
        NSColor(red: 0.25, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(red: 0.2, green: 0.86, blue: 0.78, alpha: 1),
        NSColor(NotchTheme.accent),
    ]

    private let cornerRadius: CGFloat
    private let colors: [NSColor]
    private let gradient = CAGradientLayer()
    private let strokeMask = CAShapeLayer()

    init(cornerRadius: CGFloat, colors: [NSColor]? = nil) {
        self.cornerRadius = cornerRadius
        self.colors = colors ?? Self.rainbow
        super.init(frame: .zero)
        wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        // `self.colors` — the parameter is optional and Optional.map would
        // keypath the array itself, not its elements.
        gradient.colors = self.colors.map(\.cgColor)
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
