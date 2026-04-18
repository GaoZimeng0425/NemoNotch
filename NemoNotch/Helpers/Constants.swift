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

    // Animation durations
    static let openSpringDuration: Double = 0.314
    static let closeSpringDuration: Double = 0.236
    static let badgeSpringDuration: Double = 0.35
    static let badgeSpringBounce: Double = 0.15

    // Hook server
    static let hookBasePort: UInt16 = 49200
    static let hookMaxPortAttempts: UInt16 = 10

    // Tab content
    static let tabContentHorizontalPadding: CGFloat = 20
    static let tabContentTopPadding: CGFloat = 8
    static let tabBarTopPadding: CGFloat = 10
    static let cornerRadiusClosed: CGFloat = 8
    static let cornerRadiusOpened: CGFloat = 24
    static let notchBackgroundSpacing: CGFloat = 16
}
