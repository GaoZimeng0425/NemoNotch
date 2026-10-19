import AppKit
import SwiftUI

/// One session's ring: the phase in its colour, the source's mark inside.
///
/// Motion is beats, never loops (an active SwiftUI animation re-walks the
/// display list every frame — see AGENTS.md "Collapsed-State View Tree"):
/// - working: a short arc turned by Core Animation (`EdgeBarSpinningArc`) —
///   the render server pays, not SwiftUI;
/// - waiting for approval: one amber wave out of the ring per `beat`;
/// - waiting for input (review): one swell + glow on arrival, then still;
/// - idle: still grey.
struct EdgeBarRing: View {
    let phase: SessionPhase
    let source: AISource
    /// The beat counter; only a waiting ring is handed a live one.
    let beat: Int

    private var size: CGFloat {
        EdgeBarMetrics.ringSize
    }

    private let line: CGFloat = 1.6

    var body: some View {
        // Built outside the animator: its content closure is nonisolated.
        let mark = EdgeBarSourceMark(source: source, size: size * 0.56, color: EdgeBarPalette.phase(phase))
        let glow = glowColor
        let line = line
        return ring
            .frame(width: size, height: size)
            .animation(EdgeBarMotion.rows, value: kind)
            // Above the phase-dependent drawing, never inside a branch:
            // keyframeAnimator fires on a CHANGE of its trigger, so a host
            // rebuilt by a phase change would miss the arrival it exists for.
            .keyframeAnimator(
                initialValue: RingGesture(),
                trigger: RingTrigger(kind: kind, beat: kind == .waiting ? beat : 0)
            ) { view, g in
                view
                    .background { RingWave(progress: g.wave, line: line) }
                    .overlay { mark }
                    .scaleEffect(g.pulse)
                    .shadow(color: glow.opacity(g.glow), radius: EdgeBarMetrics.ringSize * 0.35)
            } keyframes: { _ in
                KeyframeTrack(\.pulse) {
                    for key in RingGesture.pulse(for: kind) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.glow) {
                    for key in RingGesture.glow(for: kind) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.wave) {
                    for key in RingGesture.wave(for: kind) {
                        LinearKeyframe(key.value, duration: key.duration)
                    }
                }
            }
    }

    private var kind: RingKind {
        RingKind(phase)
    }

    @ViewBuilder private var ring: some View {
        switch kind {
        case .idle:
            Circle().stroke(Color.white.opacity(0.28), lineWidth: line)
        case .working:
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
                EdgeBarSpinningArc(lineWidth: line)
            }
        case .waiting:
            Circle()
                .stroke(EdgeBarPalette.amber, lineWidth: line)
                .background(Circle().fill(EdgeBarPalette.amber.opacity(0.18)))
        case .review:
            Circle().stroke(EdgeBarPalette.green.opacity(0.8), lineWidth: line)
        }
    }

    private var glowColor: Color {
        kind == .review ? EdgeBarPalette.green : .clear
    }
}

/// The waiting ring's wave: travels out of the ring and fades; 0 draws none.
struct RingWave: View {
    let progress: Double
    let line: CGFloat

    var body: some View {
        if progress > 0 {
            let t = CGFloat(progress)
            Circle()
                .stroke(EdgeBarPalette.amber, lineWidth: line * (1 - t * 0.5))
                .scaleEffect(1 + 0.5 * t)
                .opacity(0.85 * (1 - t))
        }
    }
}

/// The ring's look, coarser than `SessionPhase` (an approval's context
/// changing must not replay the arrival gesture).
enum RingKind: Equatable {
    case idle, working, waiting, review

    init(_ phase: SessionPhase) {
        switch phase {
        case .processing, .compacting: self = .working
        case .waitingForApproval: self = .waiting
        case .waitingForInput: self = .review
        case .idle, .ended: self = .idle
        }
    }
}

struct RingTrigger: Equatable {
    var kind: RingKind
    var beat: Int
}

/// The animated values of one gesture, and the table per kind. Every track
/// ends where it started, so the ring always rests in its still state.
struct RingGesture {
    var pulse: Double = 1
    var glow: Double = 0
    var wave: Double = 0

    struct Key {
        var value: Double
        var duration: Double
    }

    static func pulse(for kind: RingKind) -> [Key] {
        kind == .review ? [Key(value: 1.25, duration: 0.15), Key(value: 1, duration: 0.5)] : []
    }

    static func glow(for kind: RingKind) -> [Key] {
        kind == .review ? [Key(value: 1, duration: 0.15), Key(value: 0, duration: 1.6)] : []
    }

    static func wave(for kind: RingKind) -> [Key] {
        kind == .waiting ? [Key(value: 1, duration: 1.1), Key(value: 0, duration: 0)] : []
    }
}

/// A source's brand mark at ring scale.
struct EdgeBarSourceMark: View {
    let source: AISource
    let size: CGFloat
    let color: Color

    var body: some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, color: color)
                .frame(width: size, height: size)
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(color)
        case .opencode:
            OpencodeLogoIcon(size: size, color: color)
        case .zcode:
            ZcodeLogoIcon(size: size, color: color)
        }
    }

    static func name(_ source: AISource) -> String {
        switch source {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .opencode: "opencode"
        case .zcode: "zcode"
        }
    }
}

/// The working ring's arc, turned by Core Animation without a stop. The one
/// continuous motion on the bar, deliberately outside SwiftUI.
struct EdgeBarSpinningArc: NSViewRepresentable {
    var lineWidth: CGFloat

    func makeNSView(context: Context) -> EdgeBarSpinningArcView {
        EdgeBarSpinningArcView(lineWidth: lineWidth)
    }

    func updateNSView(_ view: EdgeBarSpinningArcView, context: Context) {}
}

final class EdgeBarSpinningArcView: NSView {
    static let length: CGFloat = 0.3
    static let period: CFTimeInterval = 1.2
    private static let key = "turn"

    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeEnd = Self.length
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    /// Never a click target (and never hidden-by-opacity eating clicks).
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset = lineWidth / 2
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        arc.contentsScale = window.backingScaleFactor
        guard arc.animation(forKey: Self.key) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise on screen.
        turn.toValue = (layer?.contentsAreFlipped() ?? false) ? 2 * Double.pi : -2 * Double.pi
        turn.duration = Self.period
        turn.repeatCount = .infinity
        // A 20pt arc reads smooth at 30fps; every frame is render-server work.
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.key)
    }
}
