import SwiftUI

/// Single-line text that scrolls horizontally in a wrap-around loop when it
/// overflows its container, and renders statically when it fits. The scroll
/// restarts whenever the text or available width changes.
struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .primary
    /// Gap between the trailing end of the text and its wrapped copy.
    var spacing: CGFloat = 28
    /// Scroll speed in points per second.
    var speed: CGFloat = 28
    /// Dwell before each scroll cycle starts.
    var initialDelay: TimeInterval = 1.5

    @State private var textSize: CGSize = .zero
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool {
        textSize.width > containerWidth + 0.5
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: spacing) {
                measuredText
                if overflows {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                }
            }
            .offset(x: offset)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in containerWidth = width }
        }
        .frame(height: textSize.height)
        .onChange(of: textSize) { _, _ in refresh() }
        .onChange(of: containerWidth) { _, _ in refresh() }
    }

    private var measuredText: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textSize = geo.size }
                        .onChange(of: geo.size) { _, size in textSize = size }
                }
            )
    }

    /// Snap back to rest, then loop only while overflowing. Assigning the
    /// offset without animation cancels any in-flight repeatForever loop.
    private func refresh() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
        guard overflows, speed > 0 else { return }
        let distance = textSize.width + spacing
        withAnimation(
            .linear(duration: Double(distance / speed))
                .delay(initialDelay)
                .repeatForever(autoreverses: false)
        ) {
            offset = -distance
        }
    }
}
