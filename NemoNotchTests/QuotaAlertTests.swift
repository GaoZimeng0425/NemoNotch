import Foundation
@testable import NemoNotch
import Testing

/// `QuotaAlertDetector`: edges of a window's share used against the
/// threshold — exceeded on the way up (arrival included), recovered only
/// once it is `hysteresis` under; a window missing from a reading changes nothing.
@Suite("QuotaAlertDetector")
struct QuotaAlertDetectorTests {
    private let claude5h = QuotaAlertKey(provider: .claude, window: .fiveHour)
    private let claude7d = QuotaAlertKey(provider: .claude, window: .sevenDay)

    private func reading(_ key: QuotaAlertKey, _ utilization: Double, resetsAt: Date? = nil) -> QuotaReading {
        QuotaReading(key: key, utilization: utilization, resetsAt: resetsAt)
    }

    @Test func crossingUpFiresExceededOnce() {
        let first = QuotaAlertDetector.plan(readings: [reading(claude5h, 79.9)], above: [], threshold: 80)
        #expect(first.events.isEmpty)
        #expect(first.above.isEmpty)
        let second = QuotaAlertDetector.plan(readings: [reading(claude5h, 80)], above: first.above, threshold: 80)
        #expect(second.events == [.exceeded(reading(claude5h, 80))])
        #expect(second.above == [claude5h])
        let third = QuotaAlertDetector.plan(readings: [reading(claude5h, 91)], above: second.above, threshold: 80)
        #expect(third.events.isEmpty)
        #expect(third.above == [claude5h])
    }

    @Test func aFirstReadingAlreadyOverFires() {
        let outcome = QuotaAlertDetector.plan(readings: [reading(claude5h, 95)], above: [], threshold: 80)
        #expect(outcome.events == [.exceeded(reading(claude5h, 95))])
    }

    @Test func recoveryNeedsTheHysteresis() {
        let wobble = QuotaAlertDetector.plan(readings: [reading(claude5h, 76)], above: [claude5h], threshold: 80)
        #expect(wobble.events.isEmpty)
        #expect(wobble.above == [claude5h])
        let reset = QuotaAlertDetector.plan(readings: [reading(claude5h, 74.9)], above: [claude5h], threshold: 80)
        #expect(reset.events == [.recovered(reading(claude5h, 74.9))])
        #expect(reset.above.isEmpty)
    }

    @Test func aMissingWindowKeepsItsState() {
        let outcome = QuotaAlertDetector.plan(readings: [], above: [claude5h], threshold: 80)
        #expect(outcome.events.isEmpty)
        #expect(outcome.above == [claude5h])
    }

    @Test func windowsAreIndependentAndOrdered() {
        let outcome = QuotaAlertDetector.plan(
            readings: [reading(claude5h, 85), reading(claude7d, 40)],
            above: [claude7d],
            threshold: 80
        )
        #expect(outcome.events == [.exceeded(reading(claude5h, 85)), .recovered(reading(claude7d, 40))])
        #expect(outcome.above == [claude5h])
    }

    @Test func aFullThresholdFiresOnlyAtOneHundred() {
        let near = QuotaAlertDetector.plan(readings: [reading(claude5h, 99.9)], above: [], threshold: 100)
        #expect(near.events.isEmpty)
        let full = QuotaAlertDetector.plan(readings: [reading(claude5h, 100)], above: [], threshold: 100)
        #expect(full.events == [.exceeded(reading(claude5h, 100))])
    }

    @Test func readingsComeOnlyFromValidQuotasWithTiers() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quotas: [QuotaProvider: ProviderUsageQuota] = [
            .claude: ProviderUsageQuota(provider: .claude, status: .valid, tiers: [
                QuotaTier(window: .fiveHour, utilization: 81, resetsAt: reset),
                QuotaTier(window: .sevenDay, utilization: 12, resetsAt: nil),
            ]),
            .codex: ProviderUsageQuota(provider: .codex, status: .expired, tiers: [
                QuotaTier(window: .rolling(minutes: 300), utilization: 99, resetsAt: nil),
            ]),
            .gemini: ProviderUsageQuota(provider: .gemini, status: .valid, tiers: [], errorMessage: "timeout"),
        ]
        #expect(QuotaAlertDetector.readings(from: quotas) == [
            QuotaReading(key: claude5h, utilization: 81, resetsAt: reset),
            QuotaReading(key: claude7d, utilization: 12, resetsAt: nil),
        ])
    }
}

/// `QuotaAlerts`: the pending list — one alert per window, the newest
/// event speaks for it; acknowledging removes it.
@Suite("QuotaAlerts")
struct QuotaAlertsTests {
    private let claude5h = QuotaAlertKey(provider: .claude, window: .fiveHour)
    private let codex5h = QuotaAlertKey(provider: .codex, window: .rolling(minutes: 300))
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func anEventBecomesAPendingAlert() {
        let reading = QuotaReading(key: claude5h, utilization: 83, resetsAt: t0.addingTimeInterval(3600))
        let alerts = QuotaAlerts.apply([.exceeded(reading)], to: [], threshold: 80, now: t0)
        #expect(alerts == [QuotaAlert(
            key: claude5h, kind: .exceeded, utilization: 83,
            resetsAt: t0.addingTimeInterval(3600), threshold: 80, firedAt: t0
        )])
        #expect(alerts[0].id == "claude:5h:exceeded")
    }

    @Test func recoveryReplacesTheWindowsExceededAlert() {
        let exceeded = QuotaAlerts.apply(
            [.exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil))],
            to: [], threshold: 80, now: t0
        )
        let later = t0.addingTimeInterval(600)
        let alerts = QuotaAlerts.apply(
            [.recovered(QuotaReading(key: claude5h, utilization: 2, resetsAt: nil))],
            to: exceeded, threshold: 80, now: later
        )
        #expect(alerts == [QuotaAlert(
            key: claude5h,
            kind: .recovered,
            utilization: 2,
            resetsAt: nil,
            threshold: 80,
            firedAt: later
        )])
    }

    @Test func windowsQueueOldestFirstAndAReplacedOneMovesLast() {
        let a = QuotaAlerts.apply(
            [.exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil))],
            to: [],
            threshold: 80,
            now: t0
        )
        let b = QuotaAlerts.apply(
            [.exceeded(QuotaReading(key: codex5h, utilization: 90, resetsAt: nil))],
            to: a,
            threshold: 80,
            now: t0.addingTimeInterval(60)
        )
        #expect(b.map(\.id) == ["claude:5h:exceeded", "codex:300m:exceeded"])
        let c = QuotaAlerts.apply(
            [.recovered(QuotaReading(key: claude5h, utilization: 1, resetsAt: nil))],
            to: b,
            threshold: 80,
            now: t0.addingTimeInterval(120)
        )
        #expect(c.map(\.id) == ["codex:300m:exceeded", "claude:5h:recovered"])
    }

    @Test func acknowledgingRemovesOnlyThatAlert() {
        let a = QuotaAlerts.apply(
            [
                .exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil)),
                .exceeded(QuotaReading(key: codex5h, utilization: 90, resetsAt: nil)),
            ],
            to: [], threshold: 80, now: t0
        )
        #expect(QuotaAlerts.acknowledging("claude:5h:exceeded", in: a).map(\.id) == ["codex:300m:exceeded"])
        #expect(QuotaAlerts.acknowledging("nobody", in: a) == a)
    }

    @Test func keyIDsNameTheWindow() {
        #expect(QuotaAlertKey(provider: .claude, window: .sevenDayOpus).id == "claude:7d-opus")
        #expect(QuotaAlertKey(provider: .gemini, window: .gemini(label: "2.5 Pro")).id == "gemini:2.5 Pro")
        #expect(QuotaAlertKey(provider: .zcode, window: .rolling(minutes: 10080)).id == "zcode:10080m")
    }
}
