import CoreLocation
import Foundation

@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
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
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.requestAlwaysAuthorization()

        // Immediately fetch by IP as fallback
        fetchWeather()
        locationManager.startMonitoringSignificantLocationChanges()

        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchWeather()
        }
    }

    deinit { timer?.invalidate() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        fetchWeather(coordinate: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
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

        if let desc = (now["weatherDesc"] as? [[String: String]])?.first?["value"] {
            condition = desc
        }

        if let weather = json["weather"] as? [[String: Any]], let today = weather.first {
            highTemp = Double(today["maxtempC"] as? String ?? "0") ?? 0
            lowTemp = Double(today["mintempC"] as? String ?? "0") ?? 0

            if let hourly = today["hourly"] as? [[String: Any]] {
                let currentHour = Calendar.current.component(.hour, from: Date())
                let allItems: [(String, Double, String)] = hourly.compactMap { h in
                    guard let time = h["time"] as? String,
                          let temp = h["tempC"] as? String else { return nil }
                    let hour = Int(time) ?? 0
                    let descArray = h["weatherDesc"] as? [[String: String]]
                    let icon = descArray?.first?["value"] ?? ""
                    let formatted = String(format: "%02d:00", hour)
                    return (formatted, Double(temp) ?? 0, icon)
                }
                hourlyForecast = allItems.filter { item in
                    let h = Int(item.0.prefix(2)) ?? 0
                    return h >= currentHour
                }.prefix(3).map { $0 }
            }
        }

        if let area = json["nearest_area"] as? [[String: Any]], let first = area.first {
            cityName = (first["areaName"] as? [[String: String]])?.first?["value"] ?? ""
        }

        isLoaded = true
    }
}
