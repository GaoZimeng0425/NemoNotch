import AppKit
import SwiftUI

// Core Animation hosts for the two always-on media animations (vinyl spin,
// equalizer bars). They live on the collapsed media badge, i.e. they run for as
// long as music plays. Driven from SwiftUI (TimelineView / withAnimation loops)
// they made the ViewGraph re-walk the whole notch window every frame — sampled
// at ~23% of a core while playing (2026-10-30). Here the motion runs in the
// render server and SwiftUI only hears about play/pause and artwork changes —
// the `CompletionToastRingView` / `EdgeBarSpinningArc` pattern.

// MARK: - Vinyl spinner

/// Rasterizes `face` once per `faceID` and turns the bitmap with a
/// `CABasicAnimation` at the shared `VinylClock` phase — pause holds the
/// angle, resume continues from it, and every disc shows the same angle.
/// What the rasterized face depends on; a new value re-renders it.
struct VinylFaceID: Equatable {
    let image: ObjectIdentifier?
    let size: CGFloat
    let showDisc: Bool
}

struct VinylSpinner<Face: View>: NSViewRepresentable {
    let face: Face
    let faceID: VinylFaceID
    /// Room around the face for strokes that straddle its edge — they must
    /// not be cropped by the rasterizer.
    let bleed: CGFloat
    let isPlaying: Bool

    func makeNSView(context: Context) -> VinylSpinnerView {
        VinylSpinnerView()
    }

    func updateNSView(_ view: VinylSpinnerView, context: Context) {
        if view.faceID != faceID {
            view.faceID = faceID
            view.setFace(render(), bleed: bleed)
        }
        view.setPlaying(isPlaying)
    }

    private func render() -> CGImage? {
        let renderer = ImageRenderer(content: face.padding(bleed))
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return renderer.cgImage
    }
}

/// The one phase every disc reads. The collapsed coin and the opened-panel
/// disc are two views morphing into each other, each recreated on every
/// open/close — per-view angles would snap the cover upright on each morph.
/// Pure (media time in, phase out) so pause/resume continuity is testable.
struct VinylClock: Equatable {
    /// Seconds per turn — 60°/s, the speed the disc has always had.
    static let period: CFTimeInterval = 6

    private(set) var isPlaying = false
    /// Paused: the frozen phase. Playing: the media time at which phase was 0.
    private var anchor: CFTimeInterval = 0

    /// Seconds into the current turn, in `0 ..< period`.
    func phase(at now: CFTimeInterval) -> CFTimeInterval {
        let raw = (isPlaying ? now - anchor : anchor).truncatingRemainder(dividingBy: Self.period)
        return raw < 0 ? raw + Self.period : raw
    }

    /// Idempotent: repeated calls with the same value change nothing, so every
    /// disc can report the shared play state without resetting it.
    mutating func setPlaying(_ playing: Bool, at now: CFTimeInterval) {
        guard playing != isPlaying else { return }
        // Pausing: anchor becomes the current phase. Resuming: anchor becomes
        // the media time the frozen phase corresponds to. Same expression.
        anchor = now - anchor
        isPlaying = playing
    }
}

final class VinylSpinnerView: NSView {
    private static let key = "spin"
    private static var clock = VinylClock()

    var faceID: VinylFaceID?
    private let disc = CALayer()
    private var bleed: CGFloat = 0
    /// What this view last rendered; nil until the first `setPlaying`.
    private var appliedPlaying: Bool?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        disc.contentsGravity = .resizeAspect
        layer?.addSublayer(disc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    /// Never a click target: a hit-testing NSView here would swallow clicks
    /// meant for the SwiftUI around it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setFace(_ image: CGImage?, bleed: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.contents = image
        self.bleed = bleed
        CATransaction.commit()
        needsLayout = true
    }

    func setPlaying(_ playing: Bool) {
        Self.clock.setPlaying(playing, at: CACurrentMediaTime())
        guard playing != appliedPlaying else { return }
        appliedPlaying = playing
        applyClock()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(
            x: 0, y: 0,
            width: bounds.width + 2 * bleed,
            height: bounds.height + 2 * bleed
        )
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        disc.contentsScale = window.backingScaleFactor
        // Animations can be dropped while out of a window; re-sync to the clock.
        applyClock()
    }

    /// Pose the disc at the shared phase: a static angle while paused, a spin
    /// that starts at that phase while playing.
    private func applyClock() {
        let clock = Self.clock
        let phase = clock.phase(at: CACurrentMediaTime())
        // Clockwise on screen.
        let turn = (layer?.contentsAreFlipped() ?? false) ? 2 * Double.pi : -2 * Double.pi
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.removeAnimation(forKey: Self.key)
        disc.transform = CATransform3DMakeRotation(turn * phase / VinylClock.period, 0, 0, 1)
        if clock.isPlaying, window != nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = turn
            spin.duration = VinylClock.period
            spin.timeOffset = phase
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: Self.key)
        }
        CATransaction.commit()
    }
}

// MARK: - Equalizer bars

/// One bar's looping height track. Pure so the loop's shape is testable;
/// the view hands each bar its own track so the bars never move in step.
struct EqualizerKeyframes: Equatable {
    let heights: [CGFloat]
    let keyTimes: [Double]
    let duration: CFTimeInterval

    /// Steps last 0.25–0.5s like the old `withAnimation` ticks. The track
    /// starts and ends at `rest` so the loop seam and the start from the
    /// idle state are both invisible.
    static func make(
        steps: Int,
        rest: CGFloat,
        maxHeight: CGFloat,
        using rng: inout some RandomNumberGenerator
    ) -> EqualizerKeyframes {
        let steps = max(steps, 2)
        let durations = (0 ..< steps).map { _ in Double.random(in: 0.25 ... 0.5, using: &rng) }
        let total = durations.reduce(0, +)
        var elapsed = 0.0
        var keyTimes = [0.0]
        for step in durations {
            elapsed += step
            keyTimes.append(elapsed / total)
        }
        keyTimes[keyTimes.count - 1] = 1
        let peaks = (1 ..< steps).map { _ in CGFloat.random(in: rest ... maxHeight, using: &rng) }
        return EqualizerKeyframes(heights: [rest] + peaks + [rest], keyTimes: keyTimes, duration: total)
    }
}

struct EqualizerBars: NSViewRepresentable {
    let isActive: Bool
    let barCount: Int
    let maxHeight: CGFloat
    let barWidth: CGFloat
    let spacing: CGFloat
    let color: Color

    func makeNSView(context: Context) -> EqualizerBarsView {
        EqualizerBarsView(barCount: barCount, maxHeight: maxHeight, barWidth: barWidth, spacing: spacing)
    }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.setColor(NSColor(color).cgColor)
        view.setActive(isActive)
    }
}

final class EqualizerBarsView: NSView {
    static let restHeight: CGFloat = 2
    private static let key = "bounce"
    private static let steps = 8

    private let bars: [CALayer]
    private let maxHeight: CGFloat
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private var isActive = false

    init(barCount: Int, maxHeight: CGFloat, barWidth: CGFloat, spacing: CGFloat) {
        bars = (0 ..< barCount).map { _ in CALayer() }
        self.maxHeight = maxHeight
        self.barWidth = barWidth
        self.spacing = spacing
        super.init(frame: .zero)
        wantsLayer = true
        for bar in bars {
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setColor(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = color
        }
        CATransaction.commit()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startBouncing()
        } else {
            for bar in bars {
                bar.removeAnimation(forKey: Self.key)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: Self.restHeight)
            bar.position = CGPoint(
                x: CGFloat(index) * (barWidth + spacing) + barWidth / 2,
                y: bounds.midY
            )
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for bar in bars {
            bar.contentsScale = window.backingScaleFactor
        }
        // Animations can be dropped while the view is out of a window.
        if isActive, bars.first?.animation(forKey: Self.key) == nil {
            startBouncing()
        }
    }

    private func startBouncing() {
        var rng = SystemRandomNumberGenerator()
        for bar in bars {
            let track = EqualizerKeyframes.make(
                steps: Self.steps,
                rest: Self.restHeight,
                maxHeight: maxHeight,
                using: &rng
            )
            let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
            bounce.values = track.heights
            bounce.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
            bounce.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: track.heights.count - 1
            )
            bounce.duration = track.duration
            bounce.repeatCount = .infinity
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: Self.key)
        }
    }
}
