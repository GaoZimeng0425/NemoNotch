import AppKit
import SwiftUI

/// Places the detail card beside the open body, level with its row. The
/// placing layout is ALWAYS in the tree and the card comes and goes inside
/// it: SwiftUI plays no transition for a view whose container arrives with
/// it (the first card would pop in).
struct EdgeBarCardLayer: View {
    @Environment(EdgeBarController.self) private var bar

    var body: some View {
        EdgeBarCardLayout(
            side: bar.side,
            slot: bar.cardSlot,
            level: bar.cardLevel,
            offset: bar.scrollOffset,
            barTop: bar.barTop,
            canvasHeight: bar.canvasHeight
        ) {
            if bar.isOpen, let id = bar.selectedRow {
                card(id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                        bar.cardFrameChanged(rect)
                    }
                    .onDisappear { bar.cardFrameChanged(nil) }
                    // A drag closes the bar inside a no-animation transaction
                    // (`EdgeBarController.instant`), which suppresses this
                    // transition's own fade — the card goes at once.
                    .transition(EdgeBarMotion.cardTransition(bar.side))
            }
        }
        // Beside the open body, on its open side.
        .padding(bar.side.edge, bar.anchorInset + bar.openWidth + EdgeBarMetrics.cardGap)
        .animation(EdgeBarMotion.length, value: bar.cardSlot)
        .animation(EdgeBarMotion.length, value: bar.cardLevel)
    }

    /// A usage section's card, or a session's.
    @ViewBuilder private func card(_ id: String) -> some View {
        if let provider = EdgeBarUsage.provider(ofCardID: id) {
            if let detail = bar.usageDetail(provider) {
                EdgeBarUsageCard(detail: detail)
            }
        } else if let row = bar.content.rows.first(where: { $0.id == id }), let session = bar.session(id) {
            EdgeBarCard(row: row, session: session)
        }
    }
}

/// Positions the card where `EdgeBarMetrics.cardTop` says for the height it
/// has **in the same pass** — real layout, not `.offset` (an offset moves
/// pixels only; the card's frame reports and hover rect would lag or lie).
struct EdgeBarCardLayout: Layout {
    let side: EdgeBarSide
    let slot: Int
    /// A usage section's top, when its card is the one placed.
    let level: CGFloat?
    let offset: CGFloat
    let barTop: CGFloat
    let canvasHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for card in subviews {
            let size = card.sizeThatFits(ProposedViewSize(width: EdgeBarMetrics.cardWidth, height: nil))
            let top = if let level {
                EdgeBarMetrics.cardTop(level: level, height: size.height, barTop: barTop, canvasHeight: canvasHeight)
            } else {
                EdgeBarMetrics.cardTop(
                    slot: slot, offset: offset, height: size.height,
                    barTop: barTop, canvasHeight: canvasHeight
                )
            }
            card.place(
                at: CGPoint(x: side == .left ? bounds.minX : bounds.maxX, y: bounds.minY + top),
                anchor: side == .left ? .topLeading : .topTrailing,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

/// One session in detail, evlat's card. Two blocks told apart by space:
/// WHO — the source in small capitals, the session's name, its branch — then
/// HOW — the status in its phase colour with time-in-phase and the turn's
/// tool count, a section edge to edge (the turn's last tool and its subject
/// on grey, a held permission on amber with Deny/Allow, or the last reply),
/// and last the way back: "Open in <app>".
struct EdgeBarCard: View {
    @Environment(EdgeBarController.self) private var bar
    let row: EdgeBarRow
    let session: AISessionState

    private static let padding: CGFloat = 18
    private static let corner: CGFloat = 16
    private static let blockGap: CGFloat = 18
    private static let sectionGap: CGFloat = 12
    private static let actionGap: CGFloat = 18
    private static let ground = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)
    private static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    private var body_: EdgeBarCardModel.Body {
        EdgeBarCardModel.body(of: session)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        let content = body_
        VStack(alignment: .leading, spacing: 0) {
            identity
                .padding(.horizontal, Self.padding)
            status
                .padding(.horizontal, Self.padding)
                .padding(.top, Self.blockGap)
            if let context = row.context {
                contextLine(context)
                    .padding(.horizontal, Self.padding)
                    .padding(.top, 10)
            }
            section(content)
            if row.hasHost {
                goButton
                    .padding(.horizontal, Self.padding)
                    .padding(.top, Self.actionGap)
            }
        }
        .padding(.top, Self.padding)
        // A section ends the card when nothing follows it: it runs to the foot.
        .padding(.bottom, row.hasHost || !Self.isSection(content) ? Self.padding : 0)
        .frame(width: EdgeBarMetrics.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Self.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        .animation(EdgeBarMotion.cardContent, value: row)
    }

    private static func isSection(_ body: EdgeBarCardModel.Body) -> Bool {
        switch body {
        case .approval, .tool: true
        case .reply, .none: false
        }
    }

    // MARK: - Who

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                EdgeBarSourceMark(source: row.source, size: 10, color: Self.secondary)
                    .frame(width: 10, height: 10)
                Text(verbatim: EdgeBarSourceMark.name(row.source).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: row.name)
                .font(.system(size: 15, weight: .semibold))
                .kerning(-0.15)
                .foregroundStyle(EdgeBarPalette.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let branch = session.gitBranch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .medium))
                    Text(verbatim: branch)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Self.secondary)
                .padding(.top, 5)
            }
        }
    }

    // MARK: - How

    private var status: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(EdgeBarPalette.phase(row.phase))
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(verbatim: EdgeBarPalette.label(row.phase))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EdgeBarPalette.phase(row.phase))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: "· " + EdgeBarCardModel.meta(
                    waited: context.date.timeIntervalSince(row.since),
                    tools: session.turnToolCount
                ))
                .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)))
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    /// "Context ▬▬▭▭ 161K / 1M · 16%", the model under it: the latest
    /// call's prompt against the window it ran in.
    private func contextLine(_ context: EdgeBarContext) -> some View {
        let tint = context.isHot ? EdgeBarPalette.amber : EdgeBarPalette.textPrimary
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("edge_bar.context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(tint.opacity(context.isHot ? 1 : 0.7))
                                .frame(width: max(geo.size.width * context.fraction, 4))
                        }
                    }
                Text(verbatim: "\(context.amountText) · \(context.percentText)")
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)))
                    .foregroundStyle(context.isHot ? EdgeBarPalette.amber : EdgeBarPalette.textPrimary.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let model = session.displayModel {
                Text(verbatim: model)
                    .font(.system(size: 10))
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func section(_ content: EdgeBarCardModel.Body) -> some View {
        switch content {
        case let .approval(tool, input):
            sectionGround(ask: true, gap: 10) {
                sectionTitle(tool)
                if !input.isEmpty {
                    ScrollView {
                        Text(verbatim: input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(EdgeBarPalette.textPrimary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 92)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
                }
                HStack(spacing: 8) {
                    cardButton(.deny, title: String(localized: "edge_bar.deny"), loud: false)
                    cardButton(.allow, title: String(localized: "edge_bar.allow"), loud: true)
                }
                .padding(.top, 2)
            }
            .padding(.top, Self.sectionGap)
        case let .tool(name, subject):
            sectionGround(ask: false, gap: 6) {
                sectionTitle(name)
                if let subject, !subject.isEmpty {
                    Text(verbatim: subject)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EdgeBarPalette.textPrimary)
                        .lineSpacing(2)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Self.sectionGap)
        case let .reply(text):
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(EdgeBarPalette.textPrimary.opacity(0.82))
                .lineSpacing(2)
                .lineLimit(4)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.padding)
                .padding(.top, 10)
        case .none:
            EmptyView()
        }
    }

    /// Edge to edge: grey for what the session is doing, amber for what it asks.
    private func sectionGround(
        ask: Bool,
        gap: CGFloat,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            content()
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ask ? EdgeBarPalette.amber.opacity(0.07) : Color.white.opacity(0.04))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.secondary)
            .lineLimit(1)
    }

    // MARK: - Buttons (plain drawing — the click is the controller's, by frame)

    private var goButton: some View {
        let hovered = bar.hoveredButton == .jump
        let pressed = bar.pressedButton == .jump
        return HStack(spacing: 6) {
            Text(verbatim: EdgeBarCardModel.goTitle(host: bar.hostName(of: session)))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(EdgeBarPalette.textPrimary.opacity(0.75))
        }
        .foregroundStyle(EdgeBarPalette.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(hovered ? 0.16 : 0.11)))
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .reportingFrame(.jump, to: bar)
    }

    private func cardButton(_ button: EdgeBarController.CardButton, title: String, loud: Bool) -> some View {
        let hovered = bar.hoveredButton == button
        let pressed = bar.pressedButton == button
        return Text(verbatim: title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(loud ? Color.black : EdgeBarPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(loud ? EdgeBarPalette.amber.opacity(hovered ? 1 : 0.9) : Color.white
                    .opacity(hovered ? 0.16 : 0.10)))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .reportingFrame(button, to: bar)
    }
}

private extension View {
    /// A drawn button's rectangle for the controller's geometry-routed click;
    /// cleared when it goes.
    func reportingFrame(_ button: EdgeBarController.CardButton, to bar: EdgeBarController) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bar.buttonFrameChanged(button, $0) }
            .onDisappear { bar.buttonFrameChanged(button, nil) }
    }
}
