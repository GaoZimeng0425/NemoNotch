import Foundation
@testable import NemoNotch
import Testing

struct VinylClockTests {
    @Test func startsPausedAtPhaseZero() {
        let clock = VinylClock()
        #expect(!clock.isPlaying)
        #expect(clock.phase(at: 1234) == 0)
    }

    @Test func playingAdvancesWithMediaTime() {
        var clock = VinylClock()
        clock.setPlaying(true, at: 100)
        #expect(clock.phase(at: 102.5) == 2.5)
    }

    @Test func pauseFreezesThePhase() {
        var clock = VinylClock()
        clock.setPlaying(true, at: 100)
        clock.setPlaying(false, at: 104)
        #expect(clock.phase(at: 104) == 4)
        #expect(clock.phase(at: 500) == 4)
    }

    @Test func resumeContinuesFromTheFrozenPhase() {
        var clock = VinylClock()
        clock.setPlaying(true, at: 100)
        clock.setPlaying(false, at: 104)
        clock.setPlaying(true, at: 300)
        #expect(clock.phase(at: 300) == 4)
        #expect(clock.phase(at: 301) == 5)
    }

    @Test func repeatedSameStateDoesNotReset() {
        // Two discs (morph ends) both report the play state; the second
        // report must not restart the turn.
        var clock = VinylClock()
        clock.setPlaying(true, at: 100)
        clock.setPlaying(true, at: 103)
        #expect(clock.phase(at: 103) == 3)
        clock.setPlaying(false, at: 104)
        clock.setPlaying(false, at: 110)
        #expect(clock.phase(at: 200) == 4)
    }

    @Test func phaseWrapsAtOneTurn() {
        var clock = VinylClock()
        clock.setPlaying(true, at: 0)
        #expect(clock.phase(at: VinylClock.period + 1) == 1)
    }
}
