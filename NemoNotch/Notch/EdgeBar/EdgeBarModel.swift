import AppKit
import SwiftUI

/// Pure model of the edge bar's content: one row per engaged AI session,
/// attention-ordered, plus the closed bar's slots and the summary line.
/// Drawn by `EdgeBarView`; decided here, unit-tested, no store or UI.
struct EdgeBarRow: Identifiable, Equatable {
    let id: String
    let name: String
    let source: AISource
    let phase: SessionPhase
    let hasHost: Bool
    /// When the session entered its current phase (the status line's clock).
    let since: Date
}

/// evlat's phase palette: idle grey, working white, waiting amber, review
/// (waiting-for-input) green. NemoNotch has no failed phase.
enum EdgeBarPalette {
    static let body = Color.black
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.5, green: 0.5, blue: 0.5)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.18)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.45)

    static func phase(_ phase: SessionPhase) -> Color {
        switch phase {
        case .processing, .compacting: textPrimary
        case .waitingForApproval: amber
        case .waitingForInput: green
        case .idle, .ended: textSecondary
        }
    }

    static func label(_ phase: SessionPhase) -> String {
        switch phase {
        case .processing: String(localized: "edge_bar.running")
        case .compacting: String(localized: "edge_bar.compacting")
        case .waitingForApproval: String(localized: "edge_bar.waiting_approval")
        case .waitingForInput: String(localized: "edge_bar.waiting_input")
        case .idle, .ended: String(localized: "edge_bar.idle")
        }
    }

    /// Status line under a name: "waiting for approval · 14 min".
    static func statusLine(_ phase: SessionPhase, waited: TimeInterval) -> String {
        let minutes = Int(waited / 60)
        let time = minutes >= 1
            ? String(format: String(localized: "edge_bar.min_fmt"), minutes)
            : String(localized: "edge_bar.moments")
        return "\(label(phase)) · \(time)"
    }
}

enum EdgeBarModel {
    struct Content: Equatable {
        /// Every engaged session, attention-ordered (the open list).
        var rows: [EdgeBarRow]
        /// What the closed bar draws as rings (at most `slotCount`, the last
        /// slot giving way to "+N" when more are folded).
        var closedRows: [EdgeBarRow]
        /// Sessions folded into "+N" on the closed bar.
        var overflow: Int
        var summary: String

        static let empty = Content(rows: [], closedRows: [], overflow: 0, summary: "")

        /// Slots the closed bar uses: its rings, plus one for "+N".
        var closedSlots: Int {
            closedRows.count + (overflow > 0 ? 1 : 0)
        }
    }

    /// Fold the store's sessions into bar content: every session that has
    /// not ended, idle ones included (grey, last).
    ///
    /// Order is evlat's: by layer — approval, running, parked at the prompt,
    /// idle — and NEVER by an event stamp that moves while the phase holds
    /// (every tool call refreshed it, so two running sessions swapped places
    /// at event rate). Running and approval rows tie by session id (stable);
    /// a parked or idle row by the moment it got there (it holds still),
    /// newest first.
    static func content(of sessions: [AISessionState]) -> Content {
        let rows = sessions
            .filter { $0.phase != .ended }
            .sorted(by: precedes)
            .map { session in
                EdgeBarRow(
                    id: session.id,
                    name: session.recordName ?? session.projectFolder ?? session.displayTitle,
                    source: session.source,
                    phase: session.phase,
                    // A tab link alone can jump (AppActivator tries it first).
                    hasHost: session.launchingAppPID != nil || session.launchingAppBundleId != nil
                        || session.tabLinkURL != nil,
                    since: session.phaseChangedAt ?? session.lastEventTime
                )
            }
        guard !rows.isEmpty else { return .empty }

        let waiting = rows.filter(\.phase.isWaitingForApproval).count
        let running = rows.filter { layer($0.phase) == 1 }.count
        let summary = String(
            format: String(localized: "edge_bar.summary"),
            rows.count, waiting, running
        )
        let slots = EdgeBarMetrics.slotCount
        let closed = rows.count > slots ? Array(rows.prefix(slots - 1)) : rows
        return Content(rows: rows, closedRows: closed, overflow: rows.count - closed.count, summary: summary)
    }

    static func precedes(_ left: AISessionState, _ right: AISessionState) -> Bool {
        let l = layer(left.phase)
        let r = layer(right.phase)
        if l != r {
            return l < r
        }
        if l >= 2 {
            let lt = left.phaseChangedAt ?? left.lastEventTime
            let rt = right.phaseChangedAt ?? right.lastEventTime
            if lt != rt {
                return lt > rt
            }
        }
        return left.id < right.id
    }

    /// Approval, running, parked at the prompt, idle.
    static func layer(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval: 0
        case .processing, .compacting: 1
        case .waitingForInput: 2
        case .idle, .ended: 3
        }
    }

    // MARK: - Measured open width

    static var nameFont: NSFont {
        .systemFont(ofSize: 11, weight: .medium)
    }

    static var statusFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    }

    static var summaryFont: NSFont {
        .systemFont(ofSize: 9, weight: .medium)
    }

    /// The open body's width, measured from the text it will hold: the
    /// longest name or status line (at its widest form, so the body doesn't
    /// move as minutes pass), or the summary line if wider — capped. With no
    /// row there is nothing to open for: the closed width.
    static func openWidth(of content: Content, usage: [EdgeBarUsageLine] = []) -> CGFloat {
        let usageWidth = min(EdgeBarUsage.minWidth(usage), EdgeBarMetrics.maxOpenWidth)
        guard !content.rows.isEmpty else {
            return usage.isEmpty ? EdgeBarMetrics.barWidth : max(EdgeBarMetrics.minOpenWidth, usageWidth)
        }
        let widest = content.rows.map { row in
            max(
                textWidth(row.name, font: nameFont),
                textWidth(EdgeBarPalette.statusLine(row.phase, waited: 99 * 60), font: statusFont)
            )
        }.max() ?? 0
        let names = EdgeBarMetrics.openWidth(namesWidth: min(ceil(widest), EdgeBarMetrics.nameMaxWidth))
        let summary = ceil(textWidth(content.summary, font: summaryFont))
            + EdgeBarMetrics.ringLead + EdgeBarMetrics.nameInset
        return min(max(names, summary, usageWidth), EdgeBarMetrics.maxOpenWidth)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
