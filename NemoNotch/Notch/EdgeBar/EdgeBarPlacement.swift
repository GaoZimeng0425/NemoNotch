import CoreGraphics
import Foundation

/// The bar's anchored side. Docked: the screen edge it hugs. Floating: the
/// capsule's end that stays put — the head sits there, and more sessions,
/// the opened list and the card all extend away from it.
enum EdgeBarSide: String, Codable, Sendable {
    case left, right
}

/// Where the bar lives (persisted): docked to a screen's left or right edge
/// as the vertical bar, or floating anywhere as a horizontal capsule. Pure
/// data and arithmetic; the controller turns it into a window frame.
struct EdgeBarPlacement: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case docked, floating
    }

    var mode: Mode
    var side: EdgeBarSide
    /// The display's UUID (`NSScreen.displayUUID`); nil, or a display that
    /// is gone, means the default screen (built-in, else the first).
    var screen: String?
    /// The bar's top as a share of the visible height from its top; nil =
    /// the default height. Docked and floating share it: the capsule's head
    /// sits where the docked bar's head does.
    var top: CGFloat?
    /// Floating: the anchored end's x, as a share of the visible width from
    /// its left.
    var anchor: CGFloat = 0

    static let standard = EdgeBarPlacement(mode: .docked, side: .left)

    /// A capsule released this close to a screen's left or right edge docks.
    static let snapDistance: CGFloat = 24

    /// Where a capsule released at `capsule` (AppKit screen coordinates)
    /// settles on a screen whose visible frame is `visible`: docked to an
    /// edge it was released near, else floating where it is.
    static func dropped(
        capsule: CGRect,
        visible: CGRect,
        side: EdgeBarSide,
        top: CGFloat,
        screen: String?
    ) -> EdgeBarPlacement {
        if capsule.minX - visible.minX <= snapDistance {
            return EdgeBarPlacement(mode: .docked, side: .left, screen: screen, top: top)
        }
        if visible.maxX - capsule.maxX <= snapDistance {
            return EdgeBarPlacement(mode: .docked, side: .right, screen: screen, top: top)
        }
        let anchorX = side == .left ? capsule.minX : capsule.maxX
        return EdgeBarPlacement(
            mode: .floating,
            side: side,
            screen: screen,
            top: top,
            anchor: (anchorX - visible.minX) / max(1, visible.width)
        )
    }

    /// The side a floating capsule anchors on: its left end while the
    /// opened list and card (`reach`) fit to the right of it, else its
    /// right end. `hysteresis` keeps a capsule dragged along the line from
    /// flipping back and forth.
    static func floatingSide(
        leftEnd: CGFloat,
        visible: CGRect,
        reach: CGFloat,
        current: EdgeBarSide,
        hysteresis: CGFloat = 24
    ) -> EdgeBarSide {
        let room = visible.maxX - leftEnd
        switch current {
        case .left: return room >= reach ? .left : .right
        case .right: return room >= reach + hysteresis ? .left : .right
        }
    }

    // MARK: Persistence

    static let defaultsKey = "edgeBarPlacement"
    /// What the left-only bar kept: its top as a share of the height.
    static let legacyTopKey = "edgeBarTopFraction"

    static func load(from defaults: UserDefaults) -> EdgeBarPlacement {
        if let data = defaults.data(forKey: defaultsKey),
           let placement = try? JSONDecoder().decode(EdgeBarPlacement.self, from: data) {
            return placement
        }
        var placement = standard
        placement.top = (defaults.object(forKey: legacyTopKey) as? Double).map { CGFloat($0) }
        return placement
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
