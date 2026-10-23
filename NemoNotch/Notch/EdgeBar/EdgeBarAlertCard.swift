import Foundation

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
