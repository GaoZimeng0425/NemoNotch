import CoreGraphics
import Foundation

/// Geometry of the toast row under the notch, in the toast panel's flipped
/// (top-left origin) coordinates. One source for both drawing and pointer
/// resolution, so a click and the pixels can never disagree about where a
/// card or its close button is (non-activating panel: SwiftUI hover/tap are
/// unreliable, the hosting view resolves events from this geometry).
struct CompletionToastLayout {
    enum Hit: Equatable {
        case close(Int)
        case card(Int)
    }

    static let cardWidth: CGFloat = 280
    static let cardHeight: CGFloat = 66
    static let spacing: CGFloat = 8
    /// Gap between the notch's bottom edge and the top of the row. Clears
    /// the notch's hover hitbox (`hitboxPadding` below the notch) — a card
    /// inside it would open the notch on hover, which hides the row.
    static let topGap: CGFloat = NotchConstants.hitboxPadding + 4
    /// Close button: a square in the card's top-trailing corner. The hit
    /// square is larger than the drawn glyph so it is easy to hit.
    static let closeSize: CGFloat = 22
    static let closeInset: CGFloat = 4

    /// The panel's fixed width: room for `capacity` cards side by side.
    static func panelWidth(capacity: Int) -> CGFloat {
        CGFloat(capacity) * cardWidth + CGFloat(max(capacity - 1, 0)) * spacing
    }

    let panelWidth: CGFloat
    let count: Int

    /// Cards are centered horizontally as a group, top-aligned in the panel.
    func cardRect(at index: Int) -> CGRect {
        let rowWidth = CGFloat(count) * Self.cardWidth + CGFloat(max(count - 1, 0)) * Self.spacing
        let x = (panelWidth - rowWidth) / 2 + CGFloat(index) * (Self.cardWidth + Self.spacing)
        return CGRect(x: x, y: 0, width: Self.cardWidth, height: Self.cardHeight)
    }

    func closeRect(at index: Int) -> CGRect {
        let card = cardRect(at: index)
        return CGRect(
            x: card.maxX - Self.closeInset - Self.closeSize,
            y: card.minY + Self.closeInset,
            width: Self.closeSize,
            height: Self.closeSize
        )
    }

    var cardRects: [CGRect] {
        (0 ..< count).map(cardRect(at:))
    }

    func hit(_ point: CGPoint) -> Hit? {
        for index in 0 ..< count {
            if closeRect(at: index).contains(point) {
                return .close(index)
            }
            if cardRect(at: index).contains(point) {
                return .card(index)
            }
        }
        return nil
    }
}

/// What a click on the toast row does — pure, so the controller only executes.
/// × always just closes; the card body jumps to the session's host app and
/// closes the card, or only closes it when there is nowhere to jump.
enum CompletionToastClick: Equatable {
    case dismiss(UUID)
    case jump(UUID, CompletionJump)

    static func action(for hit: CompletionToastLayout.Hit?, toasts: [CompletionToast]) -> CompletionToastClick? {
        switch hit {
        case let .close(index):
            guard toasts.indices.contains(index) else { return nil }
            return .dismiss(toasts[index].id)
        case let .card(index):
            guard toasts.indices.contains(index) else { return nil }
            let toast = toasts[index]
            guard let jump = toast.item.jump else { return .dismiss(toast.id) }
            return .jump(toast.id, jump)
        case nil:
            return nil
        }
    }
}
