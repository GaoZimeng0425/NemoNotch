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

    /// The side a floating capsule (`length` long) anchors on: the one it
    /// has while the opened list and card (`reach`) still fit beside it —
    /// a head never swaps ends while it needn't — else its left end while
    /// they fit to the right, else its right end while they fit to the
    /// left, else whichever side has more room.
    static func floatingSide(
        leftEnd: CGFloat,
        length: CGFloat,
        visible: CGRect,
        reach: CGFloat,
        current: EdgeBarSide
    ) -> EdgeBarSide {
        let roomRight = visible.maxX - leftEnd
        let roomLeft = leftEnd + length - visible.minX
        switch current {
        case .left where roomRight >= reach: return .left
        case .right where roomLeft >= reach: return .right
        default: break
        }
        if roomRight >= reach {
            return .left
        }
        if roomLeft >= reach {
            return .right
        }
        return roomRight >= roomLeft ? .left : .right
    }

    /// A carried capsule's anchored end, kept where the capsule (`length`
    /// long, as it is now) stays on the screen — and reaches either edge,
    /// to dock there.
    static func clampedAnchor(_ x: CGFloat, side: EdgeBarSide, length: CGFloat, visible: CGRect) -> CGFloat {
        side == .left
            ? min(max(visible.minX, x), visible.maxX - length)
            : min(max(visible.minX + length, x), visible.maxX)
    }

    /// A floating placement fitted to a screen (on release, after a
    /// resolution change or a moved Dock): its side kept while its panel
    /// still has room, else re-chosen; its anchored end kept where the
    /// opened list and card fit on the screen. The capsule stays where it
    /// is unless the screen is too narrow for it to.
    func refitted(visible: CGRect, length: CGFloat, reach: CGFloat) -> EdgeBarPlacement {
        guard mode == .floating else { return self }
        let anchorX = visible.minX + anchor * visible.width
        let leftEnd = side == .left ? anchorX : anchorX - length
        let side = Self.floatingSide(leftEnd: leftEnd, length: length, visible: visible, reach: reach, current: side)
        let x = side == .left
            ? min(max(leftEnd, visible.minX), max(visible.minX, visible.maxX - reach))
            : max(min(leftEnd + length, visible.maxX), min(visible.maxX, visible.minX + reach))
        var fitted = self
        fitted.side = side
        fitted.anchor = (x - visible.minX) / max(1, visible.width)
        return fitted
    }

    // MARK: Persistence

    private enum CodingKeys: String, CodingKey {
        case mode, side, screen, top, anchor
    }

    init(mode: Mode, side: EdgeBarSide, screen: String? = nil, top: CGFloat? = nil, anchor: CGFloat = 0) {
        self.mode = mode
        self.side = side
        self.screen = screen
        self.top = top
        self.anchor = anchor
    }

    /// Lenient: a field this version doesn't know is ignored, one it adds
    /// later is optional here — an older or newer save never decodes to
    /// "forget where the user put the bar".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        side = try c.decode(EdgeBarSide.self, forKey: .side)
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        top = try c.decodeIfPresent(CGFloat.self, forKey: .top)
        anchor = try c.decodeIfPresent(CGFloat.self, forKey: .anchor) ?? 0
    }

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
