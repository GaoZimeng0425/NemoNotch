# Weather + System Widgets Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Weather and System info tabs to NemoNotch, following existing Tab/Service patterns.

**Architecture:** Two new `@Observable` services (`WeatherService`, `SystemService`) injected via `.environment()`. Two new tab views rendering their data. Tab enum gets two new cases. Weather uses CoreLocation + wttr.in API (free, no key). System uses sysctl + IOKit.

**Tech Stack:** Swift 5, SwiftUI, CoreLocation, Foundation (URLSession, sysctl), IOKit

---

### Task 1: Add weather and system cases to Tab enum

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`

Add `weather` and `system` cases to the enum, with icons and titles:

```swift
// Add after .launcher:
case weather
case system

// In icon:
case .weather: "cloud.sun.fill"
case .system: "gearshape.2"

// In title:
case .weather: "天气"
case .system: "系统"
```

Commit: `feat: add weather and system tab cases`

---

### Task 2: Create SystemService

**Files:**
- Create: `NemoNotch/Services/SystemService.swift`

```swift
import Foundation
import IOKit.ps

@Observable
final class SystemService {
    var cpuUsage: Double = 0
    var cpuHistory: [Double] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var batteryLevel: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = -1 // -1 = unknown
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0

    private var timer: Timer?
    private let maxHistory = 60

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    deinit { timer?.invalidate() }

    func update() {
        updateCPU()
        updateMemory()
        updateBattery()
        updateDisk()
    }

    private func updateCPU() {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var prevTotal: Double = 0
        var prevIdle: Double = 0

        // Use host_processor_info for CPU usage
        let result = withUnsafeMutablePointer(to: &numCPU) { numCPUPtr in
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, numCPUPtr, &cpuInfo, &numCPUInfo)
        }

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return }

        var total: Double = 0
        var idle: Double = 0
        let numCores = Int(numCPU)
        for i in 0..<numCores {
            let user = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_USER])
            let system = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_SYSTEM])
            let nice = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_NICE])
            let idleVal = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_IDLE])
            total += user + system + nice + idleVal
            idle += idleVal
        }

        let diffTotal = total - prevTotal
        let diffIdle = idle - prevIdle
        if diffTotal > 0 {
            cpuUsage = ((diffTotal - diffIdle) / diffTotal) * 100
        }

        prevTotal = total
        prevIdle = idle

        cpuHistory.append(cpuUsage)
        if cpuHistory.count > maxHistory { cpuHistory.removeFirst() }

        // Clean up
        let size = numCPUInfo * MemoryLayout<integer_t>.size
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(size))
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        memoryTotal = UInt64(ProcessInfo.processInfo.physicalMemory)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
        memoryUsed = used
    }

    private func updateBattery() {
        // Use IOKit power source
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source).takeRetainedValue() as? [String: Any] else { continue }
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                batteryLevel = capacity
            }
            if let charging = info[kIOPSIsChargingKey] as? Bool {
                isCharging = charging
            }
            if let time = info[kIOPSTimeToEmptyKey] as? Int {
                timeRemaining = time
            }
        }
    }

    private func updateDisk() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = UInt64(values?.volumeTotalCapacity ?? 0)
        diskFree = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
```

Commit: `feat: add SystemService for CPU/memory/battery/disk monitoring`

---

### Task 3: Create SystemTab view

**Files:**
- Create: `NemoNotch/Tabs/SystemTab.swift`

View should display:
- CPU usage with mini sparkline (last 60 samples)
- Memory bar (used/total with GB labels)
- Battery icon + percentage + charging indicator
- Disk free/total with GB labels

Style: dark background consistent with existing tabs. Use `.white` and `.white.opacity(0.6)` for text.

Commit: `feat: add SystemTab view for system info display`

---

### Task 4: Create WeatherService

**Files:**
- Create: `NemoNotch/Services/WeatherService.swift`

Use CoreLocation for coordinates + wttr.in JSON API for data:

```swift
import CoreLocation
import Foundation

@Observable
final class SystemService: NSObject, CLLocationManagerDelegate {
    var temperature: Double = 0
    var condition: String = "--"
    var feelsLike: Double = 0
    var highTemp: Double = 0
    var lowTemp: Double = 0
    var humidity: Int = 0
    var windSpeed: Double = 0
    var cityName: String = ""
    var hourlyForecast: [(time: String, temp: Double, icon: String)] = []
    var isLoaded: Bool = false

    private let locationManager = CLLocationManager()
    private var timer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.requestWhenInUseAuthorization()
        locationManager.startMonitoringSignificantLocationChanges()

        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchWeather()
        }
    }

    deinit { timer?.invalidate() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        fetchWeather(coordinate: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Fallback: fetch by IP
        fetchWeather()
    }

    private func fetchWeather(coordinate: CLLocationCoordinate2D? = nil) {
        var urlStr: String
        if let coord = coordinate {
            urlStr = "https://wttr.in/\(coord.latitude),\(coord.longitude)?format=j1"
        } else {
            urlStr = "https://wttr.in/?format=j1"
        }

        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            DispatchQueue.main.async {
                self?.parseWeather(json)
            }
        }.resume()
    }

    private func parseWeather(_ json: [String: Any]) {
        guard let current = json["current_condition"] as? [[String: Any]], let now = current.first else { return }

        temperature = Double(now["temp_C"] as? String ?? "0") ?? 0
        feelsLike = Double(now["FeelsLikeC"] as? String ?? "0") ?? 0
        humidity = Int(now["humidity"] as? String ?? "0") ?? 0
        windSpeed = Double(now["windspeedKmph"] as? String ?? "0") ?? 0
        condition = now["weatherDesc"] as? [[String: String]] ?? [["value": "--"]]
        if let desc = (now["weatherDesc"] as? [[String: String]])?.first?["value"] {
            condition = desc
        }

        if let weather = json["weather"] as? [[String: Any]], let today = weather.first {
            highTemp = Double(today["maxtempC"] as? String ?? "0") ?? 0
            lowTemp = Double(today["mintempC"] as? String ?? "0") ?? 0

            if let hourly = today["hourly"] as? [[String: Any]] {
                let currentHour = Calendar.current.component(.hour, from: Date())
                hourlyForecast = hourly.compactMap { h in
                    guard let time = h["time"] as? String,
                          let temp = h["tempC"] as? String else { return nil }
                    let hour = Int(time) ?? 0
                    let icon = h["weatherDesc"] as? [[String: String]] ?? []
                    let desc = icon.first?["value"] ?? ""
                    return (time: String(format: "%02d:00", hour), temp: Double(temp) ?? 0, icon: desc)
                }.filter { Int($0.time.prefix(2)) ?? 0 >= currentHour }
                .prefix(3)
                .map { $0 }
            }
        }

        if let area = json["nearest_area"] as? [[String: Any]], let first = area.first {
            cityName = (first["areaName"] as? [[String: String]])?.first?["value"] ?? ""
        }

        isLoaded = true
    }
}
```

Commit: `feat: add WeatherService with CoreLocation and wttr.in API`

---

### Task 5: Create WeatherTab view

**Files:**
- Create: `NemoNotch/Tabs/WeatherTab.swift`

View should display:
- City name + current temp (large) + condition text
- High/Low temps
- Feels like + humidity + wind speed in a row
- 3-hour forecast row
- Loading state while data fetches

Commit: `feat: add WeatherTab view for weather display`

---

### Task 6: Wire up new services and tabs

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift` - add service creation + environment injection
- Modify: `NemoNotch/Notch/NotchView.swift` - add cases to tabContent switch

In NemoNotchApp.swift `applicationDidFinishLaunching`:
```swift
let weather = WeatherService()
let system = SystemService()
self.weatherService = weather
self.systemService = system
// Add to .environment() chain:
// .environment(weather)
// .environment(system)
```

In NotchView.swift `tabContent`:
```swift
case .weather: WeatherTab()
case .system: SystemTab()
```

Commit: `feat: wire up weather and system services in app`

---

### Task 7: Build and verify

Build the project. Fix any compilation errors. Test that both new tabs appear in the tab bar and display data.

Commit any fixes: `fix: compilation and polish for weather/system tabs`
