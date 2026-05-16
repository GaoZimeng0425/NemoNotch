import SwiftUI

struct NotchBackgroundView: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let cornerRadius: CGFloat
    let spacing: CGFloat

    var body: some View {
        notchedShape
            .drawingGroup()
    }

    private var showShadow: Bool {
        status != .closed
    }

    private var notchedShape: some View {
        ZStack {
            Rectangle()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            NotchTheme.panelRaised,
                            NotchTheme.panelBase,
                            .black,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if showShadow {
                Rectangle()
                    .foregroundStyle(
                        RadialGradient(
                            colors: [
                                NotchTheme.accent.opacity(0.10),
                                .clear,
                            ],
                            center: .topLeading,
                            startRadius: 20,
                            endRadius: notchSize.width * 0.72
                        )
                    )

                Rectangle()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.11),
                                .clear,
                                NotchTheme.accent.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.screen)
                    .opacity(0.48)
            }
        }
        .mask(notchBackgroundMaskGroup)
        .frame(
            width: notchSize.width + cornerRadius * 2,
            height: notchSize.height
        )
        .shadow(
            color: .black.opacity(showShadow ? NotchConstants.openedShadowOpacity : 0),
            radius: NotchConstants.openedShadowRadius
        )
    }

    private var notchBackgroundMaskGroup: some View {
        Rectangle()
            .foregroundStyle(.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .clipShape(.rect(
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius
            ))
            .overlay {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: cornerRadius, height: cornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: cornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: cornerRadius + spacing,
                            height: cornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -cornerRadius - spacing + 0.5, y: -0.5)
            }
            .overlay {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: cornerRadius, height: cornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: cornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: cornerRadius + spacing,
                            height: cornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: cornerRadius + spacing - 0.5, y: -0.5)
            }
    }
}
