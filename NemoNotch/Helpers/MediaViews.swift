import SwiftUI

// MARK: - VinylDiscView

struct VinylDiscView: View {
    let isPlaying: Bool
    let artworkData: Data?
    let appIcon: NSImage?
    var size: CGFloat = 20
    var showDisc: Bool = true

    @State private var cachedImage: NSImage?

    var body: some View {
        // The turn runs in Core Animation (`VinylSpinner`), not SwiftUI: this
        // disc sits on the collapsed media badge for as long as music plays,
        // and a SwiftUI-driven spin (TimelineView) re-walked the whole notch
        // window every frame — ~23% of a core, sampled 2026-10-30. SwiftUI
        // only rasterizes the static face below, once per artwork change.
        let _ = PerfProbe.hit("VinylDiscView.body")
        VinylSpinner(
            face: disc,
            faceID: VinylFaceID(
                image: cachedImage.map(ObjectIdentifier.init),
                size: size,
                showDisc: showDisc
            ),
            bleed: size * 0.05,
            isPlaying: isPlaying
        )
        .frame(width: size, height: size)
        .onChange(of: artworkData) { _, _ in cacheImage() }
        .onChange(of: appIcon) { _, _ in cacheImage() }
        .onAppear { cacheImage() }
    }

    private var disc: some View {
        ZStack {
            if showDisc {
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(NotchTheme.textTertiary.opacity(0.2), lineWidth: size * 0.05)
                    )
                ForEach(0 ..< 3) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                        .frame(width: size * (0.85 - CGFloat(i) * 0.15), height: size * (0.85 - CGFloat(i) * 0.15))
                }
            }

            Group {
                if let img = cachedImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: showDisc ? size * 0.65 : size, height: showDisc ? size * 0.65 : size)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(NotchTheme.surfaceEmphasis)
                        .frame(width: showDisc ? size * 0.65 : size, height: showDisc ? size * 0.65 : size)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.3, weight: .medium))
                                .foregroundStyle(NotchTheme.textSecondary)
                        )
                }
            }

            if showDisc {
                Circle()
                    .fill(Color.black)
                    .frame(width: size * 0.1, height: size * 0.1)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
        }
    }

    private func cacheImage() {
        if let data = artworkData, let img = NSImage(data: data) {
            cachedImage = img
        } else if let icon = appIcon {
            cachedImage = icon
        } else {
            cachedImage = nil
        }
    }
}

// MARK: - AudioEqualizerView

struct AudioEqualizerView: View {
    let isActive: Bool
    var barCount: Int = 4
    var maxHeight: CGFloat = 14
    var barWidth: CGFloat = 2.5
    var color: Color = NotchTheme.accent

    private static let spacing: CGFloat = 1.5

    var body: some View {
        // Bars bounce in Core Animation (`EqualizerBars`): this view sits on
        // the collapsed media badge, and the old back-to-back `withAnimation`
        // loop kept SwiftUI re-rendering the notch window nearly every frame.
        let _ = PerfProbe.hit("AudioEqualizerView.body")
        EqualizerBars(
            isActive: isActive,
            barCount: barCount,
            maxHeight: maxHeight,
            barWidth: barWidth,
            spacing: Self.spacing,
            color: color
        )
        .frame(
            width: CGFloat(barCount) * barWidth + CGFloat(max(barCount - 1, 0)) * Self.spacing,
            height: maxHeight
        )
    }
}
