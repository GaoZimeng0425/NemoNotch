import AppKit
import SwiftUI

/// The edge bar's drawing. Pure SwiftUI for pixels; every interaction is an
/// NSView overlay (`BarInteractView`) — SwiftUI gestures and Buttons never
/// fire in this non-activating panel.
struct EdgeBarView: View {
    @Environment(EdgeBarController.self) var controller

    /// Canvas height: set by the controller's dock cycle (window and view
    /// can never disagree after a display change).
    private var canvasHeight: CGFloat {
        controller.canvasHeight
    }

    private var slots: Int {
        min(controller.rows.count, EdgeBarModel.visibleCap) + (controller.overflow > 0 ? 1 : 0)
    }

    private var bodyWidth: CGFloat {
        EdgeBarMetrics.bodyWidth(isOpen: controller.isOpen)
    }

    private var bodyLength: CGFloat {
        EdgeBarMetrics.drawnLength(slots: slots)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            bodyShape
            barContent
            if controller.cardRowId != nil {
                card
            }
        }
        .frame(
            width: EdgeBarWindow.canvasWidth,
            height: canvasHeight,
            alignment: .topLeading
        )
    }

    // MARK: - Body

    private var bodyShape: some View {
        let shape = EdgeBarShape(width: bodyWidth, length: bodyLength)
        return shape
            .fill(Color.black.opacity(0.92))
            .overlay(shape.outline.stroke(Color.white.opacity(0.14), lineWidth: 0.8))
            .frame(width: bodyWidth, height: bodyLength)
            .overlay(
                BarInteractView(onHover: { controller.bodyHover($0) })
            )
            .shadow(color: .black.opacity(0.5), radius: 10)
    }

    /// What the body holds: the head (app icon), then rings (closed) or the
    /// names list (open).
    private var barContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
                .padding(.top, EdgeBarMetrics.headTop)
            if controller.isOpen {
                openList
                    .padding(.top, EdgeBarMetrics.ringTopGap)
                    .transition(.opacity.animation(EdgeBarMotion.namesIn))
            } else {
                rings
                    .padding(.top, EdgeBarMetrics.ringTopGap)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, EdgeBarMetrics.bodyMargin)
        .frame(width: bodyWidth, alignment: .topLeading)
    }

    private var head: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: EdgeBarMetrics.headSize, height: EdgeBarMetrics.headSize)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .overlay(
                BarInteractView(
                    onTap: { controller.headTapped() },
                    isDraggingEnabled: true,
                    onDrag: { controller.beginWindowDrag($0) }
                )
            )
    }

    private var rings: some View {
        VStack(alignment: .leading, spacing: EdgeBarMetrics.ringSpacing) {
            ForEach(Array(controller.rows.enumerated()), id: \.element.id) { _, row in
                ring(row)
            }
            if controller.overflow > 0 {
                overflowBadge(controller.overflow)
            }
        }
    }

    private func ring(_ row: EdgeBarRow) -> some View {
        ZStack {
            Circle()
                .stroke(EdgeBarPalette.phase(row.phase), lineWidth: 2)
            sourceIcon(row.source)
        }
        .frame(width: EdgeBarMetrics.ringSize, height: EdgeBarMetrics.ringSize)
    }

    private func overflowBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.7))
            .frame(width: EdgeBarMetrics.ringSize, height: EdgeBarMetrics.ringSize)
    }

    // MARK: - Open list

    private var openList: some View {
        VStack(alignment: .leading, spacing: EdgeBarMetrics.ringSpacing) {
            ForEach(controller.rows) { row in
                openRow(row)
            }
            if controller.overflow > 0 {
                Text("+\(controller.overflow)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            if !controller.summary.isEmpty {
                Text(controller.summary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .padding(.top, 6)
            }
        }
    }

    private func openRow(_ row: EdgeBarRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .stroke(EdgeBarPalette.phase(row.phase), lineWidth: 2)
                sourceIcon(row.source)
            }
            .frame(width: EdgeBarMetrics.ringSize, height: EdgeBarMetrics.ringSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(EdgeBarPalette.statusLine(row.phase, waited: row.waited))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(EdgeBarPalette.phase(row.phase).opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(
            BarInteractView(onHover: { inside in
                controller.rowHover(row.id, inside: inside)
            })
        )
    }

    private func sourceIcon(_ source: AISource) -> some View {
        Group {
            switch source {
            case .claude: Text("C")
            case .gemini: Image(systemName: "sparkles")
            case .opencode: Text("O")
            case .zcode: Text("Z")
            }
        }
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.85))
    }

    // MARK: - Detail card

    /// Level with the hovered row, clamped inside the canvas.
    private var cardTop: CGFloat {
        guard let cardRowId = controller.cardRowId,
              let index = controller.rows.firstIndex(where: { $0.id == cardRowId })
        else { return EdgeBarMetrics.gutter }
        let level = EdgeBarMetrics.ringTop(index) - 10
        return min(max(level, EdgeBarMetrics.gutter), canvasHeight - 320)
    }

    @ViewBuilder
    private var card: some View {
        if let row = controller.rows.first(where: { $0.id == controller.cardRowId }),
           controller.cardRowId != nil,
           let session = controllerStoreSession(row.id) {
            cardContent(row, session)
                .frame(width: EdgeBarMetrics.cardWidth, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.45), radius: 14)
                .offset(x: bodyWidth + EdgeBarMetrics.cardGap, y: cardTop)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    private func cardContent(_ row: EdgeBarRow, _ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(EdgeBarPalette.phase(row.phase))
                    .frame(width: 8, height: 8)
                Text(row.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(EdgeBarPalette.statusLine(row.phase, waited: row.waited))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(EdgeBarPalette.phase(row.phase))
            if let tool = session.currentTool, !tool.isEmpty {
                Text(tool)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            if row.phase.isWaitingForApproval || row.hasHost {
                HStack(spacing: 6) {
                    if row.phase.isWaitingForApproval {
                        cardButton("edge_bar.deny", tint: Color(red: 1.0, green: 0.72, blue: 0.18)) {
                            controller.respondToPermission(sessionId: row.id, approved: false)
                        }
                        cardButton("edge_bar.allow", tint: Color(red: 0.36, green: 0.85, blue: 0.45)) {
                            controller.respondToPermission(sessionId: row.id, approved: true)
                        }
                    }
                    if row.hasHost {
                        cardButton("edge_bar.jump", tint: Color.white.opacity(0.85)) {
                            controller.jump(to: row)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            BarInteractView(onHover: { inside in
                controller.rowHover(row.id, inside: inside)
            })
        )
    }

    private func cardButton(_ titleKey: String, tint: Color, action: @escaping () -> Void) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16))
            .clipShape(Capsule(style: .continuous))
            .overlay(
                BarInteractView(onTap: action)
            )
    }

    // MARK: - Store access

    /// Sessions live in the store; the controller owns it. Read through the
    /// environment-injected controller to keep one source of truth.
    private func controllerStoreSession(_ id: String) -> AISessionState? {
        controller.session(id)
    }
}
