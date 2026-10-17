import Foundation
import SwiftUI

/// Pure model of the edge bar's content: one row per engaged AI session,
/// attention-ordered, plus the summary line. Drawn by `EdgeBarView`; decided
/// here, unit-tested, no store or UI.
struct EdgeBarRow: Identifiable, Equatable {
    let id: String
    let name: String
    let source: AISource
    let phase: SessionPhase
    let hasHost: Bool
    /// Seconds the session has sat in its current phase.
    let waited: TimeInterval
}

/// evlat's phase palette: idle grey, working white, waiting amber, review
/// (waiting-for-input) green, failed red. NemoNotch has no failed phase.
enum EdgeBarPalette {
    static func phase(_ phase: SessionPhase) -> Color {
        switch phase {
        case .processing, .compacting: Color(red: 0.95, green: 0.95, blue: 0.95) // working — white
        case .waitingForApproval: Color(red: 1.0, green: 0.72, blue: 0.18) // waiting — amber
        case .waitingForInput: Color(red: 0.36, green: 0.85, blue: 0.45) // review — green
        case .idle, .ended: Color(red: 0.5, green: 0.5, blue: 0.5) // idle — grey
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
        var rows: [EdgeBarRow]
        /// Sessions folded into "+N" (closed bar shows at most `cap` rings).
        var overflow: Int
        var summary: String

        static let empty = Content(rows: [], overflow: 0, summary: "")
    }

    /// The closed bar shows at most this many rings (evlat's slotCount).
    static let visibleCap = 4

    /// Fold the store's sessions into bar content. Only engaged sessions
    /// appear; attention-ordered (approval > running > input, ties by
    /// recency) so the worst state is the first ring.
    static func content(of sessions: [AISessionState], now: Date = Date()) -> Content {
        let ordered = sessions
            .filter(\.phase.isEngaged)
            .sorted { left, right in
                let l = rank(left.phase)
                let r = rank(right.phase)
                if l != r {
                    return l < r
                }
                return left.lastEventTime > right.lastEventTime
            }

        let rows = ordered.map { session in
            EdgeBarRow(
                id: session.id,
                name: session.displayTitle,
                source: session.source,
                phase: session.phase,
                hasHost: session.launchingAppPID != nil,
                waited: now.timeIntervalSince(session.phaseChangedAt ?? session.lastEventTime)
            )
        }

        let waiting = rows.filter(\.phase.isWaitingForApproval).count
        let running = rows.count - waiting
        var summary = ""
        if !rows.isEmpty {
            summary = String(
                format: String(localized: "edge_bar.summary"),
                rows.count, waiting, running
            )
        }

        guard rows.count > visibleCap else {
            return Content(rows: rows, overflow: 0, summary: summary)
        }
        return Content(rows: Array(rows.prefix(visibleCap)), overflow: rows.count - visibleCap, summary: summary)
    }

    /// Sort key: waiting (approval) first, then running, then parked at the
    /// prompt. Same priority the AI tab and the notch badges use.
    private static func rank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval: 0
        case .processing, .compacting: 1
        case .waitingForInput: 2
        case .idle, .ended: 3
        }
    }
}
