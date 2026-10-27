import IOKit.ps

/// One power-source snapshot, parsed from an IOPS description dictionary.
struct PowerSourceReading: Equatable {
    let capacity: Int
    let isCharging: Bool
    /// Adapter present — distinct from `isCharging`, which macOS drops when
    /// the battery is full while still plugged in; edges key on this.
    let externalConnected: Bool
}

/// What changed between two consecutive readings of the same source.
struct PowerSourceChange: Equatable {
    let reading: PowerSourceReading
    let levelChanged: Bool
    let chargingChanged: Bool
    /// Adapter plugged in / pulled — drives the charging capsule.
    let powerEdge: Bool
}

/// Pure edge detection behind `HUDService.readBattery()` (IOKit reads stay
/// there; everything decidable lives here so it can be tested).
enum PowerSourceEdge {
    /// The reading HUD/capsule track, picked from all IOPS descriptions.
    static func trackedReading(in descriptions: [[String: Any]]) -> PowerSourceReading? {
        descriptions.first.map(reading(from:))
    }

    static func reading(from info: [String: Any]) -> PowerSourceReading {
        let capacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 0
        let charging = info[kIOPSIsChargingKey] as? Bool ?? false
        // "AC Power" state == adapter present. There is no public
        // "external connected" bool key — Power Source State is the
        // public signal for it (kIOPSExternalConnectedKey is private).
        let powerState = info[kIOPSPowerSourceStateKey] as? String
        let externalConnected = powerState.map { $0 == kIOPSACPowerValue } ?? charging
        return PowerSourceReading(capacity: capacity, isCharging: charging, externalConnected: externalConnected)
    }

    /// nil when nothing is news: the first reading only seeds the baseline
    /// (power already connected at launch is not a change), and an identical
    /// reading is not a change either.
    static func change(from previous: PowerSourceReading?, to current: PowerSourceReading) -> PowerSourceChange? {
        guard let previous, previous != current else { return nil }
        return PowerSourceChange(
            reading: current,
            levelChanged: current.capacity != previous.capacity,
            chargingChanged: current.isCharging != previous.isCharging,
            powerEdge: current.externalConnected != previous.externalConnected
        )
    }
}
