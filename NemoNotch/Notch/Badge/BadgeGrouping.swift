import Foundation

/// A run of active badge items sharing one icon identity (e.g. all Claude
/// sessions). Rendered as a single left logo + one right status; `count`
/// drives the right-side count chip when > 1.
struct BadgeGroup: Identifiable, Equatable {
    /// Stable icon-identity key — used as SwiftUI identity so the group's
    /// slot animates in place as its representative's status changes.
    let key: String
    /// The group's highest-priority member (input is priority-sorted, so the
    /// first member seen for a key). Drives the logo, status, and tap target.
    let representative: BadgeItem
    /// Total members in the group.
    let count: Int

    var id: String {
        key
    }

    var priority: Int {
        representative.priority
    }
}

/// The capped, display-ready badge layout: the visible groups plus the number
/// of groups folded into the trailing "+K" overflow chip.
struct BadgeCluster: Equatable {
    let groups: [BadgeGroup]
    /// K for the "+K" chip; 0 when nothing overflowed.
    let overflow: Int
}

enum BadgeGrouping {
    /// Icon-identity key: items sharing this key render the same left logo.
    /// AI groups by source, agents by emoji (empty emoji → shared Hermes icon),
    /// everything else is a singleton category.
    static func key(for item: BadgeItem) -> String {
        switch item {
        case let .ai(source, _, _, _, _): "ai:\(source.rawValue)"
        case let .agents(_, _, emoji): "agents:\(emoji)"
        case .notification: "notification"
        case .media: "media"
        case .pomodoro: "pomodoro"
        case .calendar: "calendar"
        }
    }

    /// Groups priority-sorted `items` by icon identity, preserving first-seen
    /// order. Precondition: `items` is already sorted by priority (as produced
    /// by `BadgeViewModel.activeBadgeItems`), so each key's first member is its
    /// highest-priority representative.
    static func group(_ items: [BadgeItem]) -> [BadgeGroup] {
        var order: [String] = []
        var reps: [String: BadgeItem] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let k = key(for: item)
            if reps[k] == nil {
                reps[k] = item
                order.append(k)
            }
            counts[k, default: 0] += 1
        }
        return order.map { BadgeGroup(key: $0, representative: reps[$0]!, count: counts[$0]!) }
    }

    /// Applies the display cap. When the group count exceeds `cap`, keeps the
    /// first `cap - 1` groups and reports the remainder as `overflow`.
    static func cluster(_ items: [BadgeItem], cap: Int) -> BadgeCluster {
        let all = group(items)
        guard all.count > cap else { return BadgeCluster(groups: all, overflow: 0) }
        let visible = Array(all.prefix(cap - 1))
        return BadgeCluster(groups: visible, overflow: all.count - visible.count)
    }
}
