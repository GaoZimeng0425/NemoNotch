import SwiftUI

struct NotchBackgroundView: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let hasNotch: Bool
    let cornerRadius: CGFloat
    let spacing: CGFloat

    var body: some View {
        if hasNotch {
            notchedShape
                .drawingGroup()
        } else {
            Capsule()
                .fill(.black)
                .shadow(color: .black.opacity(showShadow ? 0.4 : 0), radius: 6, y: 2)
                .drawingGroup()
        }
    }

    private var showShadow: Bool {
        status != .closed
    }

    private var notchedShape: some View {
        Rectangle()
            .foregroundStyle(.black)
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
