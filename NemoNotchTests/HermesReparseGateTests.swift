import Foundation
@testable import NemoNotch
import Testing

@Suite("Hermes session-file reparse gate")
struct HermesReparseGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Never-seen file must be parsed")
    func unseenNeedsReparse() {
        #expect(HermesService.needsReparse(currentModDate: t0, lastSeenModDate: nil))
    }

    @Test("Unchanged file is skipped")
    func unchangedSkips() {
        #expect(!HermesService.needsReparse(currentModDate: t0, lastSeenModDate: t0))
    }

    @Test("Advanced modification date triggers reparse")
    func advancedNeedsReparse() {
        let later = t0.addingTimeInterval(5)
        #expect(HermesService.needsReparse(currentModDate: later, lastSeenModDate: t0))
    }
}
