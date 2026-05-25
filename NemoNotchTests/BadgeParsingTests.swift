@testable import NemoNotch
import Testing

@Suite("DockBadge parsing")
struct BadgeParsingTests {
    @Test("Numeric label parses as integer")
    func numericLabel() {
        #expect(NotificationService.parseBadgeCount("3") == 3)
        #expect(NotificationService.parseBadgeCount("12") == 12)
        #expect(NotificationService.parseBadgeCount("  5 ") == 5)
    }

    @Test("Dot indicator parses as zero")
    func dotIndicator() {
        #expect(NotificationService.parseBadgeCount("•") == 0)
        #expect(NotificationService.parseBadgeCount("…") == 0)
    }

    @Test("Empty label parses as nil")
    func emptyLabel() {
        #expect(NotificationService.parseBadgeCount("") == nil)
        #expect(NotificationService.parseBadgeCount("   ") == nil)
    }

    @Test("Non-numeric non-dot label parses as zero (unread indicator)")
    func nonNumericLabel() {
        #expect(NotificationService.parseBadgeCount("new") == 0)
    }
}
