import SwiftUI

// MARK: - VinylDiscView

struct VinylDiscView: View {
    let isPlaying: Bool
    let artworkData: Data?
    let appIcon: NSImage?
    var size: CGFloat = 20
    var showDisc: Bool = true

    @State private var cachedImage: NSImage?

    /// 60°/s —— 与最初「每 50ms 转 3°」的转速一致。
    private static let degreesPerSecond: Double = 60

    var body: some View {
        // 用 TimelineView 驱动，而不是 repeatForever 动画。
        //
        // `paused` 为 true 时驱动直接停下，并保持最后一帧的角度 —— 暂停既可靠
        // 也不跳变。`repeatForever` 两点都做不到：它不会被 `disablesAnimations`
        // 的赋值取消（暂停后唱片照转），而且动画期间 `angle` 已经等于目标值，
        // 读不出当前插值到哪，只能清零，于是封面会瞬间跳回正上方。
        //
        // 注意 TimelineView 只看 `paused`，不看可见性：视图若「挂载但不可见」
        // 它仍会每帧更新。折叠态目前是整棵树卸载（见 NotchView.contentMounted），
        // 所以没问题 —— 但别再引入 opacity 式的隐藏。
        TimelineView(.animation(paused: !isPlaying)) { context in
            let _ = PerfProbe.hit("VinylDiscView.frame")
            disc.rotationEffect(.degrees(Self.angle(at: context.date)))
        }
        .onChange(of: artworkData) { _, _ in cacheImage() }
        .onChange(of: appIcon) { _, _ in cacheImage() }
        .onAppear { cacheImage() }
    }

    /// 角度由绝对时间推导，不存任何状态 —— 暂停/恢复无需协调，视图重建也不会
    /// 丢相位。代价是恢复播放时角度会跳到「当前时间对应的位置」，但那一跳发生
    /// 在开始旋转的瞬间，随即被转动掩盖，比暂停时跳变自然得多。
    private static func angle(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate * degreesPerSecond)
            .truncatingRemainder(dividingBy: 360)
    }

    @ViewBuilder
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

    @State private var bars: [CGFloat] = [3, 3, 3, 3]
    @State private var animateTask: Task<Void, Never>?

    var body: some View {
        let _ = PerfProbe.hit("AudioEqualizerView.body")
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
                // 每 tick 起一段 0.25–0.5s 的 withAnimation：tick 频率不高，
                // 但插值期间是满帧重绘，实际成本看 AudioEqualizerView.body 的频率。
                PerfProbe.hit("AudioEqualizerView.animTick")
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
