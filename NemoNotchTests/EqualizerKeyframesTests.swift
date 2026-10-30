import CoreGraphics
@testable import NemoNotch
import Testing

/// Deterministic generator so the random track is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct EqualizerKeyframesTests {
    private func track(steps: Int = 8, seed: UInt64 = 42) -> EqualizerKeyframes {
        var rng = SplitMix64(state: seed)
        return EqualizerKeyframes.make(steps: steps, rest: 2, maxHeight: 10, using: &rng)
    }

    @Test func loopStartsAndEndsAtRest() {
        let t = track()
        #expect(t.heights.first == 2)
        #expect(t.heights.last == 2)
    }

    @Test func oneKeyTimePerHeightFromZeroToOneIncreasing() {
        let t = track()
        #expect(t.heights.count == 9)
        #expect(t.keyTimes.count == t.heights.count)
        #expect(t.keyTimes.first == 0)
        #expect(t.keyTimes.last == 1)
        #expect(zip(t.keyTimes, t.keyTimes.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func peaksStayWithinRange() {
        let t = track()
        #expect(t.heights.allSatisfy { $0 >= 2 && $0 <= 10 })
        // Not a flat line: the bar actually moves.
        #expect(t.heights.contains { $0 > 2 })
    }

    @Test func durationIsStepsTimesQuarterToHalfSecond() {
        let t = track(steps: 8)
        #expect(t.duration >= 8 * 0.25)
        #expect(t.duration <= 8 * 0.5)
    }

    @Test func fewerThanTwoStepsIsClampedToTwo() {
        let t = track(steps: 0)
        #expect(t.heights.count == 3)
        #expect(t.keyTimes == [0, t.keyTimes[1], 1])
    }

    @Test func differentSeedsGiveDifferentTracks() {
        #expect(track(seed: 1) != track(seed: 2))
    }
}
