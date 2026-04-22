import Foundation

enum NotchConstants {
    // Notch geometry
    static let defaultNotchWidth: CGFloat = 200
    static let defaultNotchHeight: CGFloat = 32
    static let openedWidth: CGFloat = 500
    static let openedHeight: CGFloat = 260
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
    static let upcomingEventThresholdMinutes: Int = 60

    // Animation durations
    static let openSpringDuration: Double = 0.314
    static let openContentDelay: Double = 0.157
    static let openTransitionOffset: CGFloat = 130
    static let badgeFadeDuration: Double = 0.3
    static let closeSpringDuration: Double = 0.236
    static let badgeSpringDuration: Double = 0.35
    static let badgeSpringBounce: Double = 0.15

    // Close animation
    static let closeContentFadeDuration: Double = 0.1

    // Shadow
    static let openedShadowRadius: CGFloat = 12
    static let openedShadowOpacity: CGFloat = 0.4

    // Hook server
    static let hookSocketPath = "/tmp/nemonotch.sock"

    // Tab content
    static let tabContentHorizontalPadding: CGFloat = 20
    static let tabContentTopPadding: CGFloat = 8
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

