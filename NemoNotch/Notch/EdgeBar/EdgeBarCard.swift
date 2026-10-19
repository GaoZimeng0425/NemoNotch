import SwiftUI

/// Places the detail card beside the open body, level with its row. The
/// placing layout is ALWAYS in the tree and the card comes and goes inside
/// it: SwiftUI plays no transition for a view whose container arrives with
/// it (the first card would pop in).
struct EdgeBarCardLayer: View {
    @Environment(EdgeBarController.self) private var bar

    var body: some View {
        EdgeBarCardLayout(
            slot: bar.cardSlot,
            offset: bar.scrollOffset,
            barTop: bar.barTop,
            canvasHeight: bar.canvasHeight
        ) {
            if bar.isOpen, let id = bar.selectedRow,
               let row = bar.content.rows.first(where: { $0.id == id }),
               let session = bar.session(id) {
                EdgeBarCard(row: row, session: session)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                        bar.cardFrameChanged(rect)
                    }
                    .onDisappear { bar.cardFrameChanged(nil) }
                    .transition(EdgeBarMotion.cardTransition)
            }
        }
        .padding(.leading, bar.openWidth + EdgeBarMetrics.cardGap)
        .animation(EdgeBarMotion.length, value: bar.cardSlot)
    }
}

/// Positions the card where `EdgeBarMetrics.cardTop` says for the height it
/// has **in the same pass** — real layout, not `.offset` (an offset moves
/// pixels only; the card's frame reports and hover rect would lag or lie).
struct EdgeBarCardLayout: Layout {
    let slot: Int
    let offset: CGFloat
    let barTop: CGFloat
    let canvasHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for card in subviews {
            let size = card.sizeThatFits(ProposedViewSize(width: EdgeBarMetrics.cardWidth, height: nil))
            let top = EdgeBarMetrics.cardTop(
                slot: slot, offset: offset, height: size.height,
                barTop: barTop, canvasHeight: canvasHeight
            )
            card.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

/// One session in detail: who and where, its status with time-in-phase, what
/// it is doing (or the tool it asks to run), and the actions — Deny/Allow
/// for a held permission, Go to session when its terminal is known.
struct EdgeBarCard: View {
    @Environment(EdgeBarController.self) private var bar
    let row: EdgeBarRow
    let session: AISessionState

    private static let padding: CGFloat = 14
    private static let corner: CGFloat = 14

    private var approval: PermissionContext? {
        if case let .waitingForApproval(context) = row.phase {
            return context
        }
        return nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            identity
            status
                .padding(.top, 10)
            what
            actions
        }
        .padding(Self.padding)
        .frame(width: EdgeBarMetrics.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 3)
        .animation(EdgeBarMotion.cardContent, value: row)
    }

    // MARK: - Sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                EdgeBarSourceMark(source: row.source, size: 12, color: EdgeBarPalette.textSecondary)
                    .frame(width: 12, height: 12)
                Text(verbatim: EdgeBarSourceMark.name(row.source))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EdgeBarPalette.textSecondary)
                if let model = session.displayModel {
                    Text(verbatim: "· \(model)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EdgeBarPalette.textSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Text(verbatim: row.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EdgeBarPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 8)
            if let cwd = session.cwd {
                Text(verbatim: (cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(EdgeBarPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(EdgeBarPalette.phase(row.phase))
                .frame(width: 6, height: 6)
            TimelineView(.everyMinute) { context in
                Text(verbatim: EdgeBarPalette.statusLine(row.phase, waited: context.date.timeIntervalSince(row.since)))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(EdgeBarPalette.phase(row.phase))
            }
        }
    }

    @ViewBuilder private var what: some View {
        if let approval {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: approval.toolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(EdgeBarPalette.amber)
                let input = approval.displayInput
                if !input.isEmpty {
                    ScrollView {
                        Text(verbatim: input)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.disabled)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 92)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(EdgeBarPalette.amber.opacity(0.10))
            )
            .padding(.top, 10)
        } else if let tool = session.currentTool, !tool.isEmpty, row.phase == .processing {
            Label {
                Text(verbatim: tool)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            } icon: {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.top, 10)
        } else if let message = session.lastMessage, !message.isEmpty {
            Text(verbatim: message)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(3)
                .padding(.top, 10)
        }
    }

    @ViewBuilder private var actions: some View {
        if approval != nil || row.hasHost {
            HStack(spacing: 8) {
                if approval != nil {
                    cardButton(.deny, titleKey: "edge_bar.deny", tint: Color.white.opacity(0.85), filled: false)
                    cardButton(.allow, titleKey: "edge_bar.allow", tint: EdgeBarPalette.amber, filled: true)
                }
                if row.hasHost {
                    cardButton(.jump, titleKey: "edge_bar.jump", tint: Color.white.opacity(0.85), filled: false)
                }
            }
            .padding(.top, 12)
        }
    }

    /// Plain drawing — the click is the controller's, by this frame.
    private func cardButton(
        _ button: EdgeBarController.CardButton,
        titleKey: String,
        tint: Color,
        filled: Bool
    ) -> some View {
        let hovered = bar.hoveredButton == button
        let pressed = bar.pressedButton == button
        return Text(LocalizedStringKey(titleKey))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Color.black : tint)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? tint.opacity(hovered ? 1 : 0.88) : Color.white.opacity(hovered ? 0.16 : 0.09))
            )
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                bar.buttonFrameChanged(button, rect)
            }
            .onDisappear { bar.buttonFrameChanged(button, nil) }
    }
}
