import SwiftUI

// MARK: - VinylDiscView

struct VinylDiscView: View {
    let isPlaying: Bool
    let artworkData: Data?
    let appIcon: NSImage?
    var size: CGFloat = 20
    var showDisc: Bool = true

    @State private var angle: Double = 0
    @State private var cachedImage: NSImage?
    @State private var rotationTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if showDisc {
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(NotchTheme.textTertiary.opacity(0.2), lineWidth: size * 0.05)
                    )
                ForEach(0..<3) { i in
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
        .rotationEffect(.degrees(angle))
        .onChange(of: artworkData) { _, _ in cacheImage() }
        .onChange(of: appIcon) { _, _ in cacheImage() }
        .onChange(of: isPlaying) { _, playing in
            playing ? startRotation() : stopRotation()
        }
        .onAppear {
            cacheImage()
            if isPlaying { startRotation() }
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

    private func startRotation() {
        rotationTask?.cancel()
        rotationTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    angle += 3
                }
            }
        }
    }

    private func stopRotation() {
        rotationTask?.cancel()
        rotationTask = nil
    }
}

// MARK: - AudioEqualizerView

struct AudioEqualizerView: View {
    let isActive: Bool
    var barCount: Int = 4
    var maxHeight: CGFloat = 14
    var barWidth: CGFloat = 2.5
    var color: Color = NotchTheme.accent

    @State private var bars: [CGFloat] = [3, 3, 3, 3]
    @State private var animateTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: isActive ? (i < bars.count ? bars[i] : 2) : 2)
            }
        }
        .frame(height: maxHeight)
        .onChange(of: isActive) { _, playing in
            playing ? startAnimation() : stopAnimation()
        }
        .onAppear { if isActive { startAnimation() } }
        .onDisappear { stopAnimation() }
    }

    private func startAnimation() {
        stopAnimation()
        animateTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: Double.random(in: 0.25...0.5))) {
                    bars = (0..<barCount).map { _ in .random(in: 2...maxHeight) }
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 250...500)))
            }
        }
    }

    private func stopAnimation() {
        animateTask?.cancel()
        animateTask = nil
    }
}
