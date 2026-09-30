import AppKit
import UniformTypeIdentifiers

/// The grab-and-drag chip inside the floating guide panel.
///
/// It is a plain drag source: it puts the app's own `.app` bundle URL on the
/// drag pasteboard as a file URL, which is exactly what System Settings'
/// privacy lists consume. Nothing here writes to TCC — the drop is still
/// performed by the user, inside System Settings.
@MainActor
final class DraggableAppIconView: NSView {
    let appURL: URL

    /// Called with `true` when the user released the drag over a valid target.
    var onDragEnded: ((Bool) -> Void)?

    private let iconView = NSImageView()
    private let icon: NSImage
    private let side: CGFloat

    init(appURL: URL, icon: NSImage, side: CGFloat = 54) {
        self.appURL = appURL
        self.icon = icon
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))

        wantsLayer = true
        layer?.cornerRadius = side / 2
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: side * 0.62),
            iconView.heightAnchor.constraint(equalToConstant: side * 0.62),
        ])

        // A grab cursor plus the ring is the only affordance saying "this
        // moves" — without it the chip reads as static artwork.
        addCursorRect(bounds, cursor: .openHand)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }

        let item = NSPasteboardItem()
        item.setString(appURL.absoluteString, forType: .fileURL)
        // Legacy filename list: some system drop targets still read this
        // instead of the modern file URL. Harmless to carry both.
        item.setPropertyList([appURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())

        alphaValue = 0.45
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Round chip + app icon as the drag image, so what trails the cursor
    /// matches what the user grabbed.
    private func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: bounds, xRadius: side / 2, yRadius: side / 2)
        NSColor(white: 0.10, alpha: 0.92).setFill()
        path.fill()
        icon.draw(
            in: bounds.insetBy(dx: side * 0.19, dy: side * 0.19),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    private func restore() {
        alphaValue = 1
    }
}

extension DraggableAppIconView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        restore()
        // An empty operation set means the drop was refused or cancelled.
        onDragEnded?(!operation.isEmpty)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Nothing to do — the drag image is already configured.
    }
}
