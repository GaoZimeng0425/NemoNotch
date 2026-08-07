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
    @State private var isRotating = false

    /// 一圈 6 秒 = 60°/s，与原先“每 50ms 转 3°”的转速一致。
    private static let secondsPerTurn: Double = 6

    var body: some View {
        let _ = PerfProbe.hit("VinylDiscView.body")
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
        // 关键：视图消失必须停转。缺这一行时，notch 折叠 / 切屏后旋转仍在跑，
        // 新视图上来又起一份，稳态下会有多份同时转（实测 4 份）。
        .onDisappear { stopRotation() }
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

    /// 声明一次无限匀速旋转，由动画系统负责插值。
    ///
    /// 相比原先每 50ms 改一次 `@State`：那样每 tick 都会让 SwiftUI 认为数据变了
    /// → 重跑 `body` → 重建视图树 → 提交 CA transaction，下游拖出
    /// `NSHostingView.layout()` / `_layoutSubtreeWithOldSize:` 递归布局。
    /// 现在 `angle` 只赋值一次，`body` 不再每帧重算。
    private func startRotation() {
        guard !isRotating else { return }
        isRotating = true
        PerfProbe.hit("VinylDiscView.startRotation")
        withAnimation(.linear(duration: Self.secondsPerTurn).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }

    /// `repeatForever` 不会自行结束，必须显式打断：用禁用动画的 transaction
    /// 重设角度，动画才会被替换掉而不是继续挂着。
    ///
    /// 归零同时让暂停时封面回正（0° 是正朝向），比停在任意角度更自然。
    private func stopRotation() {
        guard isRotating else { return }
        isRotating = false
        PerfProbe.hit("VinylDiscView.stopRotation")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            angle = 0
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
