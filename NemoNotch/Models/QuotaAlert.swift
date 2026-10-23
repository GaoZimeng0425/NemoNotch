import Foundation

/// Identifies one quota window across refreshes: which provider, which
/// rolling window. `id` feeds alert/card ids ("claude:5h") and log lines.
struct QuotaAlertKey: Hashable, Sendable {
    let provider: QuotaProvider
    let window: QuotaWindow

    var id: String {
        let windowText: String = switch window {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        case .sevenDayOpus: "7d-opus"
        case .sevenDaySonnet: "7d-sonnet"
        case let .rolling(minutes): "\(minutes)m"
        case let .gemini(label): label
        }
        return "\(provider.rawValue):\(windowText)"
    }
}

/// One window's utilization at a refresh — the detector's only input.
struct QuotaReading: Equatable, Sendable {
    let key: QuotaAlertKey
    /// Raw percent, not clamped.
    let utilization: Double
    let resetsAt: Date?
}

/// Pure detection core, unit-tested: given this round's readings, the keys
/// already over, and the threshold — which windows crossed up (exceeded; a
/// first reading already over counts, the user must learn about an exhausted
/// window at launch) and which came back down (recovered, only once clear of
/// the threshold by `hysteresis`, so a reading wobbling at the line can't
/// fire twice). A key with no reading this round keeps its state: a transient
/// fetch failure is never a recovery.
enum QuotaAlertDetector {
    enum Event: Equatable {
        case exceeded(QuotaReading)
        case recovered(QuotaReading)
    }

    struct Outcome: Equatable {
        var events: [Event] = []
        var above: Set<QuotaAlertKey> = []
    }

    /// Utilization must fall this far under the threshold before a window
    /// counts as recovered.
    static let hysteresis: Double = 5

    /// Flattens the service's per-provider quotas into readings. Only
    /// `.valid` quotas with tiers contribute — error states carry stale or
    /// no numbers and must not read as recovery.
    static func readings(from quotas: [QuotaProvider: ProviderUsageQuota]) -> [QuotaReading] {
        var readings: [QuotaReading] = []
        for provider in QuotaProvider.allCases {
            guard let quota = quotas[provider], quota.status == .valid, !quota.tiers.isEmpty else { continue }
            for tier in quota.tiers {
                readings.append(
                    QuotaReading(
                        key: QuotaAlertKey(provider: provider, window: tier.window),
                        utilization: tier.utilization,
                        resetsAt: tier.resetsAt
                    )
                )
            }
        }
        return readings
    }

    static func plan(readings: [QuotaReading], above: Set<QuotaAlertKey>, threshold: Double) -> Outcome {
        var outcome = Outcome(above: above)
        for reading in readings {
            let utilization = reading.utilization
            if !outcome.above.contains(reading.key), utilization >= threshold {
                outcome.events.append(.exceeded(reading))
                outcome.above.insert(reading.key)
            } else if outcome.above.contains(reading.key), utilization < threshold - Self.hysteresis {
                outcome.events.append(.recovered(reading))
                outcome.above.remove(reading.key)
            }
        }
        return outcome
    }
}

/// A pending alert — what the card shows. `id` carries the kind
/// ("claude:5h:exceeded"), so an exceeded alert replaced by its recovery is
/// a new id and the bar treats it as a fresh arrival.
struct QuotaAlert: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case exceeded
        case recovered
    }

    let key: QuotaAlertKey
    let kind: Kind
    let utilization: Double
    let resetsAt: Date?
    let threshold: Double
    let firedAt: Date

    var id: String {
        "\(key.id):\(kind.rawValue)"
    }
}

/// Pure fold of the pending list, unit-tested: one alert per window, the
/// newest event speaks for it (an unseen "exceeded" replaced by "recovered"
/// is not lost — the recovery card implies it); acknowledging removes it.
enum QuotaAlerts {
    static func apply(
        _ events: [QuotaAlertDetector.Event],
        to alerts: [QuotaAlert],
        threshold: Double,
        now: Date
    ) -> [QuotaAlert] {
        var alerts = alerts
        for event in events {
            let reading: QuotaReading
            let kind: QuotaAlert.Kind
            switch event {
            case let .exceeded(r):
                reading = r
                kind = .exceeded
            case let .recovered(r):
                reading = r
                kind = .recovered
            }
            alerts.removeAll { $0.key == reading.key }
            alerts.append(
                QuotaAlert(
                    key: reading.key,
                    kind: kind,
                    utilization: reading.utilization,
                    resetsAt: reading.resetsAt,
                    threshold: threshold,
                    firedAt: now
                )
            )
        }
        return alerts
    }

    static func acknowledging(_ id: String, in alerts: [QuotaAlert]) -> [QuotaAlert] {
        alerts.filter { $0.id != id }
    }
}
