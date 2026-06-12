import Foundation

enum NotchConstants {
    // Notch geometry
    static let defaultNotchWidth: CGFloat = 200
    static let defaultNotchHeight: CGFloat = 32
    static let openedWidth: CGFloat = 560
    static let overviewOpenedWidth: CGFloat = 700
    static let openedHeight: CGFloat = 328
    static let hitboxPadding: CGFloat = 10
    static let closeHitboxInset: CGFloat = 20
    static let clickHitboxInset: CGFloat = 10

    // Badge
    static let badgePadding: CGFloat = 36
    static let badgeSpread: CGFloat = 14

    // Badge row
    static let badgeRowHeight: CGFloat = 24
    static let badgeRowSpacing: CGFloat = 10

    // Badge layout
    static let closedWidthInset: CGFloat = 4
    static let upcomingEventThresholdMinutes: Int = 15

    // Animation durations
    static let openSpringDuration: Double = 0.314
    static let openContentDelay: Double = 0.157
    static let openTransitionOffset: CGFloat = 130
    static let badgeFadeDuration: Double = 0.24
    static let closeSpringDuration: Double = 0.24
    static let badgeSpringDuration: Double = 0.32
    static let badgeSpringBounce: Double = 0.08
    static let tabSwitchSpringDuration: Double = 0.28
    static let tabSwitchSpringBounce: Double = 0.06
    static let fadeFastDuration: Double = 0.16
    static let fadeNormalDuration: Double = 0.24
    static let pulseDuration: Double = 1.05

    /// How long the notch stays open after a hotkey-open with no mouse motion
    /// before auto-collapsing. Cancelled the moment the mouse enters content.
    static let hotkeyAutoCloseDelay: TimeInterval = 3.0

    /// Close animation
    static let closeContentFadeDuration: Double = 0.1

    // Shadow
    static let openedShadowRadius: CGFloat = 14
    static let openedShadowOpacity: CGFloat = 0.34

    // Activity glow (expanded notch, blurred inner edge ring — never overlaps content)
    static let glowRingOpacity: CGFloat = 0.85
    static let glowRingWidth: CGFloat = 7
    static let glowRingBlur: CGFloat = 9
    /// Vertical coverage: the glow occupies this fraction of the panel height
    /// measured from the bottom, fading to nothing above it.
    static let glowRingCoverage: CGFloat = 0.8
    /// Ambient breathing: glow opacity oscillates between min and max over this
    /// period (seconds), giving a gentle "mood light" rhythm.
    static let glowPulseDuration: Double = 2.2
    static let glowPulseMin: Double = 0.5
    static let glowPulseMax: Double = 1.0

    // Completion flash (full-screen edge glow on AI/agent completion)
    /// Cooldown window: the first completion flashes; further completions
    /// within this window merge into the visible toast without re-flashing.
    static let completionFlashThrottle: TimeInterval = 2.0
    static let completionFlashFadeIn: Double = 0.18
    static let completionFlashHold: Double = 0.15
    static let completionFlashFadeOut: Double = 0.55
    /// Thickness (points) of the accent band fading inward from each screen edge.
    static let completionGlowWidth: CGFloat = 120
    static let completionGlowBlur: CGFloat = 60
    /// Peak opacity of the edge glow at the top of the flash.
    static let completionGlowOpacity: Double = 0.55

    /// Hook server: TCP loopback (HTTP) on this default port.
    ///
    /// AF_UNIX socket files were previously used but proved unworkable on this
    /// system — bind() succeeded inside NemoNotch but the socket inode was
    /// filtered out of every other process's view of the same directory
    /// (regular files in the same directory remained visible). The mechanism
    /// is some macOS-side per-process filtering of socket inodes for this
    /// bundle id; no path change escaped it. TCP loopback bypasses VFS
    /// entirely. See reference: masko-code/Sources/Services/LocalServer.swift.
    static let hookServerDefaultPort: UInt16 = 45831
    static let hookServerMaxPortAttempts: UInt16 = 10
    private static let hookServerPortKey = "hookServerPort"

    /// Port the HookServer last successfully bound to. Falls back to default
    /// when not yet persisted. HookInstaller reads this to embed the right
    /// port in hook-sender.sh.
    static var hookServerPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: hookServerPortKey)
        if stored > 0, stored <= 65535 {
            return UInt16(stored)
        }
        return hookServerDefaultPort
    }

    static func setHookServerPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: hookServerPortKey)
    }

    // Tab content
    static let tabContentPadding: CGFloat = 16
    static let tabBarTopPadding: CGFloat = 10
    static let cornerRadiusClosed: CGFloat = 8
    static let cornerRadiusOpened: CGFloat = 24
    static let notchBackgroundSpacing: CGFloat = 16

    // HUD overlay
    static let hudHeight: CGFloat = 32
    static let hudCornerRadius: CGFloat = 16
    static let hudIconSize: CGFloat = 18
    static let hudHorizontalPadding: CGFloat = 14
    static let hudTopPadding: CGFloat = 6
    static let hudDismissDelay: Double = 2.0
    static let hudAppearDuration: Double = 0.3
    static let hudDismissDuration: Double = 0.2
    // HUD segmented bar
    static let hudSegmentWidth: CGFloat = 5
    static let hudSegmentHeight: CGFloat = 14
    static let hudSegmentSpacing: CGFloat = 2.5
    static let hudSegmentCornerRadius: CGFloat = 2
}
