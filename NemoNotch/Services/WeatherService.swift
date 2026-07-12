import AppKit
@preconcurrency import CoreLocation
import Foundation

@MainActor
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate, LifecycleAware {
    var temperature: Double = 0
    var condition: String = "--"
    var symbolName: String = "cloud.sun.fill"
    var feelsLike: Double = 0
    var highTemp: Double = 0
    var lowTemp: Double = 0
    var humidity: Int = 0
    var windSpeed: Double = 0
    var cityName: String = ""
    var hourlyForecast: [(time: String, temp: Double, icon: String)] = []
    var dailyForecast: [DailyForecast] = []
    var isLoaded: Bool = false
    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private var customCity: String = ""
    /// Last coordinate successfully reverse-geocoded (Open-Meteo path).
    private var geocodedLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationAuthorizationStatus = locationManager.authorizationStatus
        // Defer location monitoring + refresh timer until a view becomes
        // visible — see setActive(_:). The first activation triggers the
        // initial fetch.
    }

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            fetchWeather()
            // Significant-location monitoring on .notDetermined would surface
            // the system authorization dialog at launch. Defer it until the
            // user grants permission via the in-tab PermissionCard.
            if locationAuthorizationStatus == .authorizedAlways {
                locationManager.startMonitoringSignificantLocationChanges()
            }
            timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fetchWeather()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            locationManager.stopMonitoringSignificantLocationChanges()
        }
    }

    func updateCity(_ city: String) {
        customCity = city.trimmingCharacters(in: .whitespaces)
        isLoaded = false
        fetchWeather()
    }

    func requestLocationAccess() {
        LogService.info("Location permission requested by user", category: "Permission")
        locationManager.requestAlwaysAuthorization()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.locationAuthorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
                // setActive(true) earlier may have skipped this because the
                // status was .notDetermined. Start it now that the user granted.
                if self.timer != nil {
                    manager.startMonitoringSignificantLocationChanges()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            self.lastLocation = location
            if self.customCity.isEmpty {
                self.fetchWeather(coordinate: location.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            self.fetchWeather()
        }
    }

    private func fetchWeather(coordinate: CLLocationCoordinate2D? = nil) {
        // uitest 下保留 UITestSeeder 注入的假天气,禁止真实网络请求覆盖(并避免无谓的网络调用)。
        if UITestMode.isActive {
            return
        }
        let coordinate = coordinate ?? lastLocation?.coordinate
        Task {
            if !customCity.isEmpty {
                await fetchFromWTTR(city: customCity, coordinate: nil)
            } else if let coordinate {
                // Open-Meteo primary (keyless, stable); wttr.in as fallback.
                if await fetchFromOpenMeteo(coordinate: coordinate) {
                    return
                }
                await fetchFromWTTR(city: nil, coordinate: coordinate)
            } else {
                // No location yet — wttr.in geolocates by IP.
                await fetchFromWTTR(city: nil, coordinate: nil)
            }
        }
    }

    /// Returns false on any failure so the caller can fall back to wttr.in.
    private func fetchFromOpenMeteo(coordinate: CLLocationCoordinate2D) async -> Bool {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
            ),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "forecast_days", value: "7"),
            // Cap the hourly block to the next few hours; daily still spans 7 days.
            URLQueryItem(name: "forecast_hours", value: "6"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                LogService.warn("Open-Meteo HTTP \(status), falling back to wttr.in", category: "Weather")
                return false
            }
            try apply(WeatherParser.parseOpenMeteo(data: data))
            LogService.debug("Weather fetched from Open-Meteo", category: "Weather")
            resolveCityName(for: coordinate)
            return true
        } catch {
            LogService.warn(
                "Open-Meteo fetch failed, falling back to wttr.in: \(error.localizedDescription)",
                category: "Weather"
            )
            return false
        }
    }

    private func fetchFromWTTR(city: String?, coordinate: CLLocationCoordinate2D?) async {
        let location: String = if let city, !city.isEmpty {
            city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        } else if let coordinate {
            "\(coordinate.latitude),\(coordinate.longitude)"
        } else {
            ""
        }
        guard let url = URL(string: "https://wttr.in/\(location)?format=j1") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                LogService.error("wttr.in HTTP \(status)", category: "Weather")
                return
            }
            let snapshot = try WeatherParser.parseWTTR(data: data)
            apply(snapshot)
            if let name = snapshot.cityName {
                cityName = name
            }
            LogService.debug("Weather fetched from wttr.in", category: "Weather")
        } catch {
            LogService.error("wttr.in fetch failed: \(error.localizedDescription)", category: "Weather")
        }
    }

    private func apply(_ snapshot: WeatherSnapshot) {
        temperature = snapshot.temperature
        feelsLike = snapshot.feelsLike
        highTemp = snapshot.highTemp
        lowTemp = snapshot.lowTemp
        humidity = snapshot.humidity
        windSpeed = snapshot.windSpeed
        condition = snapshot.kind.localizedDescription
        symbolName = snapshot.kind.symbol(isDay: snapshot.isDay)
        hourlyForecast = snapshot.hourly
        dailyForecast = snapshot.days
        isLoaded = true
    }

    /// Open-Meteo returns no place name — reverse-geocode instead, at most
    /// once per ~1 km of movement (CLGeocoder is rate-limited).
    private func resolveCityName(for coordinate: CLLocationCoordinate2D) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let done = geocodedLocation, done.distance(from: location) < 1000, !cityName.isEmpty {
            return
        }
        Task {
            do {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                if let name = placemarks.first?.locality ?? placemarks.first?.name {
                    cityName = name
                    geocodedLocation = location
                }
            } catch {
                LogService.warn("Reverse geocoding failed: \(error.localizedDescription)", category: "Weather")
            }
        }
    }
}
