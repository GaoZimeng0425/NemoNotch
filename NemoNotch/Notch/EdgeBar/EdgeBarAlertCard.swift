import AppKit
import SwiftUI

/// When a quota alert brings its card up on its own — decided apart from
/// the controller, like `EdgeBarAutoCard`.
enum EdgeBarAlertCards {
    struct Decision: Equatable {
        var open = false
        var select: String?
    }

    static func cardID(_ alert: QuotaAlert) -> String {
        "alert:" + alert.id
    }

    static func alertID(ofCardID id: String) -> String? {
        guard id.hasPrefix("alert:") else { return nil }
        return String(id.dropFirst("alert:".count))
    }

    /// Open the closed bar for a newly arrived alert; take the card on an open
    /// one — never from a selected approval. Old alerts never reopen a folded
    /// bar; they only fill a free card.
    static func plan(
        previous: [String],
        pending: [String],
        isOpen: Bool,
        selectedRow: String?,
        approvalSelected: Bool
    ) -> Decision {
        let arrived = pending.filter { !previous.contains($0) }
        guard let firstArrival = arrived.first else {
            if isOpen, selectedRow == nil {
                return Decision(select: reclaim(pending: pending, selectedRow: nil, approvalSelected: approvalSelected))
            }
            return Decision()
        }
        if isOpen {
            return approvalSelected ? Decision() : Decision(select: firstArrival)
        }
        return Decision(open: true, select: firstArrival)
    }

    /// The pending alert to bring back when the cursor leaves (or the bar opens
    /// by hover) and nothing else has the card: oldest pending, none when an
    /// approval holds the card or a pending alert already does.
    static func reclaim(pending: [String], selectedRow: String?, approvalSelected: Bool) -> String? {
        guard !approvalSelected else { return nil }
        if let selectedRow, pending.contains(selectedRow) {
            return nil
        }
        return pending.first
    }
}

/// A pending quota alert, beside the bar: the provider in small capitals
/// with the kind's title (over the threshold in red, recovered in green),
/// the window's name and share used in its level's colour, a meter, the
/// threshold it fired against, the reset when known — and the one way the
/// card goes: 知道了. Same ground and frame as the session and usage cards.
struct EdgeBarAlertCard: View {
    @Environment(EdgeBarController.self) private var bar
    let alert: QuotaAlert

    private static let padding: CGFloat = 18
    private static let corner: CGFloat = 16
    private static let ground = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)
    private static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 14) {
                header
                windowBlock(now: context.date)
                acknowledgeButton
            }
            .padding(Self.padding)
        }
        .frame(width: EdgeBarMetrics.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Self.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        .animation(EdgeBarMotion.cardContent, value: alert)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: EdgeBarUsage.heading(alert.key.provider))
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: kindTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(kindColor)
                .lineLimit(1)
        }
    }

    private var kindTitle: String {
        switch alert.kind {
        case .exceeded: String(localized: "edge_bar.alert.exceeded")
        case .recovered: String(localized: "edge_bar.alert.recovered")
        }
    }

    private var kindColor: Color {
        alert.kind == .exceeded ? EdgeBarUsageLevel.critical.color : EdgeBarPalette.green
    }

    private func windowBlock(now: Date) -> some View {
        let level = EdgeBarUsageLevel(percent: alert.utilization)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: EdgeBarUsageCardText.name(alert.key.window))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EdgeBarPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "\(Int(alert.utilization.rounded()))%")
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)))
                    .foregroundStyle(level.color)
            }
            meter(alert.utilization / 100, color: level.color)
            Text(verbatim: String(format: String(localized: "edge_bar.alert.threshold_fmt"), Int(alert.threshold)))
                .font(.system(size: 11))
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
            if let reset = EdgeBarUsageCardText.reset(alert.resetsAt, now: now) {
                Text(verbatim: reset)
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)))
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var acknowledgeButton: some View {
        let hovered = bar.hoveredButton == .acknowledge
        let pressed = bar.pressedButton == .acknowledge
        return Text(verbatim: String(localized: "edge_bar.alert.acknowledge"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(EdgeBarPalette.amber.opacity(hovered ? 1 : 0.9)))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .reportingFrame(.acknowledge, to: bar)
    }

    private func meter(_ fraction: Double, color: Color) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.12))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: fraction > 0 ? max(geo.size.width * min(1, fraction), 5) : 0)
                }
            }
    }
}
