import AppKit
import SwiftUI

/// The edge bar's drawing. Takes no events (the hosting view routes them by
/// geometry); every layout here is pinned to the anchored side and the
/// bar's top, so the window never moves anything — opening is the shape's
/// inner edge travelling into the screen while names fade in beside rings
/// that never move. Docked right, it is the left bar mirrored (text still
/// reads left to right); floating, the closed bar is a capsule on its side.
struct EdgeBarView: View {
    @Environment(EdgeBarController.self) private var bar

    var body: some View {
        ZStack(alignment: bar.side.topAlignment) {
            Group {
                // The form changes only under a drag, which moves the window
                // in the same frame: swap at once. (The drag's no-animation
                // transaction is what makes it instant — the opened bar used
                // to ride along because closing it, outside any transaction,
                // let the Group's `isOpen` animation hold its removal.)
                if bar.isFloating {
                    EdgeBarFloatingBody()
                        .transition(.identity)
                } else {
                    barLayer
                        .transition(.identity)
                }
            }
            .padding(.top, bar.barTop)
            .padding(bar.side.edge, bar.anchorInset)
            // An opened capsule rising to fit rises on the opening's curve
            // (a drag moves it unanimated: no `isOpen` change).
            .animation(EdgeBarMotion.body, value: bar.isOpen)
            EdgeBarCardLayer()
        }
        .frame(width: bar.canvasWidth, height: bar.canvasHeight, alignment: bar.side.topAlignment)
    }

    private var barLayer: some View {
        ZStack(alignment: bar.side.topAlignment) {
            bodyShape
            bodyContent
        }
    }

    /// Everything the body holds, clipped to the body's own animating shape
    /// — so nothing (a fading usage line, a name) can ever draw past the
    /// outline while the body narrows or shortens on close.
    private var bodyContent: some View {
        EdgeBarBodyItems()
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: bar.side.topAlignment)
            .clipShape(EdgeBarMetrics.shape(bar.side))
            .animation(EdgeBarMotion.body, value: bar.isOpen)
            .animation(EdgeBarMotion.body, value: bar.openWidth)
            .animation(EdgeBarMotion.length, value: bar.bodyLength)
    }

    // MARK: - Body

    private var shapeSize: CGSize {
        CGSize(width: bar.isOpen ? bar.openWidth : EdgeBarMetrics.barWidth, height: bar.bodyLength)
    }

    private var bodyShape: some View {
        let shape = EdgeBarMetrics.shape(bar.side)
        return shape
            .fill(EdgeBarPalette.body)
            // A thin inner edge separates the body from a dark wall behind
            // it and makes the flare readable. `outline` leaves out the
            // segment on the screen edge (no hairline on the bezel).
            .overlay(shape.outline.stroke(Color.white.opacity(0.10), lineWidth: 1))
            // Cast into the screen: the shadow sells "growing out of the bezel".
            .shadow(color: .black.opacity(0.35), radius: 10, x: 3 * bar.side.sign, y: 0)
            // Opening widens and lengthens on one curve: `isOpen`'s animation
            // is innermost, so it wins over the length's.
            .frame(width: shapeSize.width, height: shapeSize.height)
            .animation(EdgeBarMotion.body, value: bar.isOpen)
            .animation(EdgeBarMotion.body, value: bar.openWidth)
            .animation(EdgeBarMotion.length, value: bar.bodyLength)
    }
}

/// What a body holds — the head, the column, the usage block — laid out
/// from the anchored side and the bar's top; the docked bar and the opened
/// capsule each clip it to their own shape.
struct EdgeBarBodyItems: View {
    @Environment(EdgeBarController.self) private var bar

    var body: some View {
        ZStack(alignment: bar.side.topAlignment) {
            EdgeBarHead()
                .padding(.top, EdgeBarMetrics.headTop)
            // A closed capsule holds its rings in a row of its own.
            if !bar.content.rows.isEmpty, bar.isOpen || !bar.isFloating {
                EdgeBarColumn()
                    .padding(.top, EdgeBarMetrics.listTop)
                    .transition(.opacity.animation(bar.isOpen ? EdgeBarMotion.namesIn : EdgeBarMotion.namesOut))
            }
            // Only while open (its minute tick never runs on the closed bar);
            // comes and goes with the names, follows the list's length.
            if bar.isOpen, !bar.usageLines.isEmpty {
                EdgeBarUsageBlock(lines: bar.usageLines, width: bar.openWidth, side: bar.side)
                    .padding(.top, EdgeBarUsage.top(rows: bar.content.rows.count))
                    .animation(EdgeBarMotion.length, value: bar.content.rows.count)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(EdgeBarMotion.namesIn),
                        removal: .opacity.animation(EdgeBarMotion.namesOut)
                    ))
            }
        }
    }
}

/// The app icon at the top of the bar (the capsule's anchored end): the
/// chat bubble's button.
struct EdgeBarHead: View {
    @Environment(EdgeBarController.self) private var bar

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: EdgeBarMetrics.headSize, height: EdgeBarMetrics.headSize)
            .scaleEffect(bar.isOverHead ? 1.08 : 1)
            .brightness(bar.isOverHead ? 0.06 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: bar.isOverHead)
            .frame(width: EdgeBarMetrics.barWidth)
            .allowsHitTesting(false)
    }
}

/// The floating form. Closed: a capsule — the closed bar on its side, the
/// head at the anchored end, the rings in a row. Open: a panel holding what
/// the docked bar holds open, grown from the capsule (the head stays put;
/// the rings give way to the list). One rounded shape morphs between the
/// two and clips both.
struct EdgeBarFloatingBody: View {
    @Environment(EdgeBarController.self) private var bar

    private var shape: EdgeBarFloatingShape {
        bar.isOpen
            ? EdgeBarFloatingShape(
                top: EdgeBarMetrics.flare,
                height: bar.bodyLength - 2 * EdgeBarMetrics.flare,
                corner: EdgeBarMetrics.corner
            )
            : EdgeBarFloatingShape(
                top: EdgeBarMetrics.capsuleTop,
                height: EdgeBarMetrics.capsuleHeight,
                corner: EdgeBarMetrics.capsuleHeight / 2
            )
    }

    private var size: CGSize {
        bar.isOpen
            ? CGSize(width: bar.openWidth, height: bar.bodyLength)
            : CGSize(
                width: EdgeBarMetrics.capsuleLength(slots: bar.content.closedSlots),
                height: EdgeBarMetrics.capsuleTop + EdgeBarMetrics.capsuleHeight
            )
    }

    var body: some View {
        let shape = shape
        ZStack(alignment: bar.side.topAlignment) {
            shape
                .fill(EdgeBarPalette.body)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 3)
            ZStack(alignment: bar.side.topAlignment) {
                EdgeBarBodyItems()
                if !bar.isOpen {
                    capsuleRings
                        .transition(.opacity.animation(EdgeBarMotion.namesOut))
                }
            }
            // Framed like the fill before clipping: clipped at its content's
            // size, the cap would shave the last ring's stroke and glow.
            .frame(width: size.width, height: size.height, alignment: bar.side.topAlignment)
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: bar.side.topAlignment)
        .animation(EdgeBarMotion.body, value: bar.isOpen)
        .animation(EdgeBarMotion.body, value: bar.openWidth)
        .animation(EdgeBarMotion.length, value: bar.bodyLength)
        .animation(EdgeBarMotion.length, value: bar.content.closedSlots)
    }

    /// The closed rings in a row from the head, the first (most urgent)
    /// nearest it; "+N" at the far end.
    private var capsuleRings: some View {
        HStack(spacing: EdgeBarMetrics.ringSpacing) {
            if bar.side == .right {
                overflow
            }
            ForEach(bar.side == .left ? bar.content.closedRows : bar.content.closedRows.reversed()) { row in
                EdgeBarRing(phase: row.phase, source: row.source, beat: bar.beat)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if bar.side == .left {
                overflow
            }
        }
        .animation(EdgeBarMotion.rows, value: bar.content)
        .padding(.top, EdgeBarMetrics.headTop + (EdgeBarMetrics.headSize - EdgeBarMetrics.ringSize) / 2)
        .padding(bar.side.edge, EdgeBarMetrics.capsuleRingStart)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var overflow: some View {
        if bar.content.overflow > 0 {
            Text(verbatim: "+\(bar.content.overflow)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(EdgeBarPalette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: EdgeBarMetrics.ringSize, height: EdgeBarMetrics.ringSize)
        }
    }
}

/// A rounded rect at `top`, `height` tall, across the frame's width: the
/// capsule and the panel are one shape at two settings, so the morph
/// between them is one interpolation (top, height, corner; the width rides
/// the frame).
struct EdgeBarFloatingShape: Shape {
    var top: CGFloat
    var height: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(top, height), corner) }
        set {
            top = newValue.first.first
            height = newValue.first.second
            corner = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: max(0, height))
        let radius = max(0, min(corner, body.height / 2, body.width / 2))
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: body)
    }
}

/// The column under the head. Closed: one ring per slot and "+N". Open:
/// every session, each ring's name as an OVERLAY on its ring — it takes no
/// room, so no ring moves when the bar opens. A view of its own so a scroll
/// or a hover re-evaluates the column, not the shape and head.
struct EdgeBarColumn: View {
    @Environment(EdgeBarController.self) private var bar

    private var rows: [EdgeBarRow] {
        bar.isOpen ? bar.content.rows : bar.content.closedRows
    }

    /// The visible area: the open list's, or the closed slots'.
    private var clipHeight: CGFloat {
        bar.isOpen
            ? EdgeBarMetrics.listHeight(rows: bar.content.rows.count)
            : CGFloat(bar.content.closedSlots) * EdgeBarMetrics.rowPitch
    }

    var body: some View {
        column
            // Opening/closing changes which rows are in the tree; they are
            // uncovered by the growing cut, not a transition of their own.
            .transaction(value: bar.isOpen) { $0.animation = nil }
            .padding(.top, EdgeBarMetrics.ringSpacing / 2)
            // Scroll follows the finger: written unanimated. Hit-testing is
            // geometry-based, so an offset is safe here.
            .offset(y: -bar.scrollOffset)
            .frame(
                width: bar.isOpen ? bar.openWidth : EdgeBarMetrics.barWidth,
                height: clipHeight,
                alignment: bar.side.topAlignment
            )
            .clipped()
            .overlay(alignment: .top) { fade(top: true) }
            .overlay(alignment: .bottom) { fade(top: false) }
            .overlay(alignment: bar.side.bottomAlignment) { summary }
            .animation(EdgeBarMotion.body, value: bar.isOpen)
            .animation(EdgeBarMotion.length, value: bar.content.rows.count)
            .allowsHitTesting(false)
    }

    private var column: some View {
        VStack(alignment: bar.side.horizontal, spacing: EdgeBarMetrics.ringSpacing) {
            // Identity is the session: a reorder travels on the spring
            // instead of rings snapping into each other's places.
            ForEach(rows) { row in
                EdgeBarRing(phase: row.phase, source: row.source, beat: bar.beat)
                    .frame(width: EdgeBarMetrics.barWidth)
                    .background(alignment: bar.side.alignment) { ground(row.id) }
                    .overlay(alignment: bar.side.alignment) {
                        EdgeBarRowLabel(row: row, isOpen: bar.isOpen, side: bar.side)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: bar.side.unitPoint)))
            }
            if !bar.isOpen, bar.content.overflow > 0 {
                Text(verbatim: "+\(bar.content.overflow)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(EdgeBarPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: EdgeBarMetrics.barWidth, height: EdgeBarMetrics.ringSize)
                    .transition(.opacity)
            }
        }
        // Keyed on the store's content, not the derived `rows` (which also
        // flips on open/close — those changes are the growing clip's).
        .animation(EdgeBarMotion.rows, value: bar.content)
    }

    /// Behind the selected row (the one the card speaks for), half as strong
    /// under the cursor alone — a row shows it answers to pointing before
    /// its card comes.
    private func ground(_ id: String) -> some View {
        let selected = bar.isOpen && bar.selectedRow == id
        let hovered = bar.isOpen && bar.hoveredRow == id
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .frame(
                width: max(0, bar.openWidth - 2 * EdgeBarMetrics.groundInset),
                height: EdgeBarMetrics.groundHeight
            )
            .offset(x: bar.side.sign * EdgeBarMetrics.groundInset, y: 1)
            .opacity(selected ? 1 : hovered ? 0.5 : 0)
            .animation(EdgeBarMotion.namesOut, value: selected)
            .animation(EdgeBarMotion.namesOut, value: hovered)
    }

    /// The body's own black over the list's scrolled edges: same as fading
    /// the rows, without an offscreen mask pass.
    @ViewBuilder private func fade(top: Bool) -> some View {
        let maxOffset = EdgeBarMetrics.maxScrollOffset(rows: bar.content.rows.count)
        let distance = top ? bar.scrollOffset : maxOffset - bar.scrollOffset
        let strength = bar.isOpen && maxOffset > 0 ? min(1, max(0, distance / min(24, maxOffset))) : 0
        if strength > 0 {
            LinearGradient(
                colors: [EdgeBarPalette.body.opacity(0), EdgeBarPalette.body],
                startPoint: top ? .bottom : .top,
                endPoint: top ? .top : .bottom
            )
            .frame(height: 24)
            .padding(bar.side.farEdge, 1)
            .opacity(strength)
        }
    }

    /// "5 sessions · 1 waiting · 4 running" under the list; comes and goes
    /// with the names.
    private var summary: some View {
        Text(verbatim: bar.content.summary)
            .font(Font(EdgeBarModel.summaryFont))
            .foregroundStyle(EdgeBarPalette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(height: EdgeBarMetrics.summaryHeight)
            .padding(bar.side.edge, EdgeBarMetrics.ringLead)
            .offset(y: EdgeBarMetrics.summaryGap + EdgeBarMetrics.summaryHeight)
            .opacity(bar.isOpen ? 1 : 0)
            .animation(bar.isOpen ? EdgeBarMotion.namesIn : EdgeBarMotion.namesOut, value: bar.isOpen)
    }
}

/// A row's name and status line, beside its ring (on the open side; text
/// hugs the ring). Comes in from under the ring (`nameTravel`) just after
/// the body starts to open, leaves before it starts to close — so no name
/// is ever drawn past the body's edge.
struct EdgeBarRowLabel: View {
    let row: EdgeBarRow
    let isOpen: Bool
    let side: EdgeBarSide

    private var lead: CGFloat {
        EdgeBarMetrics.barWidth - EdgeBarMetrics.ringLead + EdgeBarMetrics.nameGap
    }

    var body: some View {
        VStack(alignment: side.horizontal, spacing: 1) {
            Text(verbatim: row.name)
                .font(Font(EdgeBarModel.nameFont))
                .foregroundStyle(row.phase.isEngaged ? EdgeBarPalette.textPrimary : EdgeBarPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isOpen {
                // Ticks once a minute, and only while open.
                TimelineView(.everyMinute) { context in
                    Text(verbatim: EdgeBarPalette.statusLine(
                        row.phase,
                        waited: context.date.timeIntervalSince(row.since),
                        context: row.context
                    ))
                    .font(Font(EdgeBarModel.statusFont))
                    .foregroundStyle(row.phase.isWaitingForApproval ? EdgeBarPalette.amber : EdgeBarPalette
                        .textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .transition(.opacity)
            }
        }
        .frame(width: EdgeBarMetrics.nameMaxWidth, height: EdgeBarMetrics.labelHeight, alignment: side.topAlignment)
        .offset(x: side.sign * (lead - (isOpen ? 0 : EdgeBarMetrics.nameTravel)))
        .opacity(isOpen ? 1 : 0)
        .animation(isOpen ? EdgeBarMotion.namesIn : EdgeBarMotion.namesOut, value: isOpen)
    }
}
