import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarContext")
struct EdgeBarContextTests {
    @Test func rowCarriesTheSessionsContext() {
        var s = AISessionState(sessionId: "a", source: .claude)
        s.phase = .processing
        s.model = "claude-opus-5-5"
        s.lastContextTokens = 161_026
        let row = EdgeBarModel.content(of: [s]).rows.first
        #expect(row?.context == EdgeBarContext(tokens: 161_026, limit: 1_000_000))
    }

    @Test func noCallYetMeansNoContext() {
        var s = AISessionState(sessionId: "a", source: .opencode)
        s.phase = .processing
        #expect(EdgeBarModel.content(of: [s]).rows.first?.context == nil)
    }

    @Test func percentText() {
        #expect(EdgeBarContext(tokens: 161_026, limit: 1_000_000).percentText == "16%")
        #expect(EdgeBarContext(tokens: 3000, limit: 1_000_000).percentText == "<1%")
        #expect(EdgeBarContext(tokens: 250_000, limit: 200_000).percentText == "100%")
    }

    @Test func amountText() {
        #expect(EdgeBarContext(tokens: 161_026, limit: 1_000_000).amountText == "161K / 1M")
        #expect(EdgeBarContext(tokens: 950, limit: 200_000).amountText == "950 / 200K")
        #expect(EdgeBarContext.compact(1_048_576) == "1M")
        #expect(EdgeBarContext.compact(1_310_720) == "1.3M")
        #expect(EdgeBarContext.compact(999_700) == "1M")
    }

    @Test func hotFromEightyPercent() {
        #expect(!EdgeBarContext(tokens: 158_000, limit: 200_000).isHot)
        #expect(EdgeBarContext(tokens: 160_000, limit: 200_000).isHot)
        // 79.6% reads "80%": it must be amber like the text says.
        #expect(EdgeBarContext(tokens: 159_200, limit: 200_000).isHot)
    }

    @Test func statusLineEndsWithTheContextShare() {
        let line = EdgeBarPalette.statusLine(
            .processing, waited: 0,
            context: EdgeBarContext(tokens: 161_026, limit: 1_000_000)
        )
        #expect(line.hasSuffix(" · 16%"))
        #expect(!EdgeBarPalette.statusLine(.processing, waited: 0).contains("%"))
    }
}
