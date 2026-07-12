import Foundation

/// Provider-agnostic weather condition category. Both providers' numeric
/// weather codes (Open-Meteo's WMO interpretation codes, wttr.in's WWO codes)
/// collapse into one of these, which then yields the SF Symbol and localized
/// description — no locale-dependent text matching anywhere.
enum WeatherKind: Equatable {
    case clear
    case partlyCloudy
    case cloudy
    case overcast
    case fog
    case drizzle
    case rain
    case freezingRain
    case sleet
    case snow
    case showers
    case thunderstorm

    func symbol(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy, .cloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .freezingRain, .sleet: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .showers: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }

    var localizedDescription: String {
        switch self {
        case .clear: String(localized: "weather.cond.clear")
        case .partlyCloudy: String(localized: "weather.cond.partly_cloudy")
        case .cloudy: String(localized: "weather.cond.cloudy")
        case .overcast: String(localized: "weather.cond.overcast")
        case .fog: String(localized: "weather.cond.fog")
        case .drizzle: String(localized: "weather.cond.drizzle")
        case .rain: String(localized: "weather.cond.rain")
        case .freezingRain: String(localized: "weather.cond.freezing_rain")
        case .sleet: String(localized: "weather.cond.sleet")
        case .snow: String(localized: "weather.cond.snow")
        case .showers: String(localized: "weather.cond.showers")
        case .thunderstorm: String(localized: "weather.cond.thunderstorm")
        }
    }

    /// WMO weather interpretation codes (Open-Meteo `weather_code`).
    static func fromWMO(_ code: Int) -> WeatherKind {
        switch code {
        case 0: .clear
        case 1, 2: .partlyCloudy
        case 3: .overcast
        case 45, 48: .fog
        case 51, 53, 55: .drizzle
        case 56, 57, 66, 67: .freezingRain
        case 61, 63, 65: .rain
        case 71, 73, 75, 77, 85, 86: .snow
        case 80, 81, 82: .showers
        case 95, 96, 99: .thunderstorm
        default: .cloudy
        }
    }

    /// WWO condition codes (wttr.in `weatherCode`).
    static func fromWWO(_ code: Int) -> WeatherKind {
        switch code {
        case 113: .clear
        case 116: .partlyCloudy
        case 119, 122: .overcast
        case 143, 248, 260: .fog
        case 263, 266: .drizzle
        case 176, 293, 296, 299, 302, 305, 308: .rain
        case 353, 356, 359: .showers
        case 185, 281, 284, 311, 314: .freezingRain
        case 179, 182, 317, 320, 350, 362, 365, 374, 377: .sleet
        case 227, 230, 323, 326, 329, 332, 335, 338, 368, 371: .snow
        case 200, 386, 389, 392, 395: .thunderstorm
        default: .cloudy
        }
    }
}

/// One day of forecast. `date` is the provider-local "yyyy-MM-dd" string.
struct DailyForecast: Equatable {
    let date: String
    let kind: WeatherKind
    let high: Double
    let low: Double

    /// "Today" (localized) for today's row, short localized weekday otherwise.
    func label(now: Date = Date()) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        if Calendar.current.isDate(day, inSameDayAs: now) {
            return String(localized: "weather.today")
        }
        let weekday = DateFormatter()
        weekday.setLocalizedDateFormatFromTemplate("EEE")
        return weekday.string(from: day)
    }
}

/// One provider response, normalized. `cityName` is nil for Open-Meteo (the
/// API returns no place name — the service reverse-geocodes instead).
struct WeatherSnapshot {
    var temperature: Double
    var feelsLike: Double
    var highTemp: Double
    var lowTemp: Double
    var humidity: Int
    var windSpeed: Double
    var kind: WeatherKind
    var isDay: Bool
    var cityName: String?
    var hourly: [(time: String, temp: Double, icon: String)]
    var days: [DailyForecast]
}

enum WeatherParseError: Error {
    case missingCurrentCondition
}

/// Pure response-to-snapshot parsing for both weather providers, kept off the
/// service so it can be unit-tested without network.
enum WeatherParser {
    // MARK: - Open-Meteo

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature2M: Double
            let apparentTemperature: Double?
            let relativeHumidity2M: Int?
            let windSpeed10M: Double?
            let weatherCode: Int?
            let isDay: Int?
        }

        struct Hourly: Decodable {
            let time: [String]
            let temperature2M: [Double]
            let weatherCode: [Int]?
        }

        struct Daily: Decodable {
            let time: [String]?
            let temperature2MMax: [Double]?
            let temperature2MMin: [Double]?
            let weatherCode: [Int]?
        }

        let current: Current
        let hourly: Hourly?
        let daily: Daily?
        let utcOffsetSeconds: Int?
    }

    static func parseOpenMeteo(data: Data, now: Date = Date()) throws -> WeatherSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(OpenMeteoResponse.self, from: data)
        let current = payload.current
        let isDay = (current.isDay ?? 1) == 1

        // Hourly times are local to the queried coordinates ("2026-07-12T15:00");
        // format `now` in that same zone so a lexicographic compare finds the
        // next entries.
        var hourly: [(time: String, temp: Double, icon: String)] = []
        if let block = payload.hourly {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            formatter.timeZone = TimeZone(secondsFromGMT: payload.utcOffsetSeconds ?? 0) ?? .current
            let nowKey = formatter.string(from: now)
            for (index, time) in block.time.enumerated() where time >= nowKey {
                guard hourly.count < 3, index < block.temperature2M.count else { break }
                let code = block.weatherCode?.indices.contains(index) == true ? block.weatherCode![index] : -1
                hourly.append((
                    time: String(time.suffix(5)),
                    temp: block.temperature2M[index],
                    icon: WeatherKind.fromWMO(code).symbol(isDay: isDay)
                ))
            }
        }

        var days: [DailyForecast] = []
        if let daily = payload.daily {
            for (index, date) in (daily.time ?? []).enumerated() {
                guard let high = daily.temperature2MMax?.indices.contains(index) == true
                    ? daily.temperature2MMax?[index] : nil,
                    let low = daily.temperature2MMin?.indices.contains(index) == true
                    ? daily.temperature2MMin?[index] : nil
                else { continue }
                let code = daily.weatherCode?.indices.contains(index) == true ? daily.weatherCode![index] : -1
                days.append(DailyForecast(date: date, kind: WeatherKind.fromWMO(code), high: high, low: low))
            }
        }

        return WeatherSnapshot(
            temperature: current.temperature2M,
            feelsLike: current.apparentTemperature ?? current.temperature2M,
            highTemp: payload.daily?.temperature2MMax?.first ?? 0,
            lowTemp: payload.daily?.temperature2MMin?.first ?? 0,
            humidity: current.relativeHumidity2M ?? 0,
            windSpeed: current.windSpeed10M ?? 0,
            kind: WeatherKind.fromWMO(current.weatherCode ?? -1),
            isDay: isDay,
            cityName: nil,
            hourly: hourly,
            days: days
        )
    }

    // MARK: - wttr.in

    private struct WTTRResponse: Decodable {
        struct TextValue: Decodable {
            let value: String
        }

        struct CurrentCondition: Decodable {
            let tempC: String
            let feelsLikeC: String?
            let humidity: String?
            let windspeedKmph: String?
            let weatherCode: String
            let isday: String?

            enum CodingKeys: String, CodingKey {
                case tempC = "temp_C"
                case feelsLikeC = "FeelsLikeC"
                case humidity
                case windspeedKmph
                case weatherCode
                case isday
            }
        }

        struct Hourly: Decodable {
            let time: String?
            let tempC: String?
            let weatherCode: String?
        }

        struct Daily: Decodable {
            let date: String?
            let maxtempC: String?
            let mintempC: String?
            let hourly: [Hourly]?
        }

        struct NearestArea: Decodable {
            let areaName: [TextValue]?
            let region: [TextValue]?
            let country: [TextValue]?

            var preferredName: String? {
                for candidate in [areaName?.first?.value, region?.first?.value, country?.first?.value] {
                    if let candidate, !candidate.isEmpty {
                        return candidate
                    }
                }
                return nil
            }
        }

        let currentCondition: [CurrentCondition]
        let weather: [Daily]?
        let nearestArea: [NearestArea]?

        enum CodingKeys: String, CodingKey {
            case currentCondition = "current_condition"
            case weather
            case nearestArea = "nearest_area"
        }
    }

    static func parseWTTR(data: Data, now: Date = Date()) throws -> WeatherSnapshot {
        let payload = try JSONDecoder().decode(WTTRResponse.self, from: data)
        guard let current = payload.currentCondition.first else {
            throw WeatherParseError.missingCurrentCondition
        }
        let kind = WeatherKind.fromWWO(Int(current.weatherCode) ?? -1)
        // wttr.in only sometimes includes `isday`; default to day when absent.
        let isDay = current.isday.map { $0 == "1" || $0.lowercased() == "yes" } ?? true
        let today = payload.weather?.first

        var hourly: [(time: String, temp: Double, icon: String)] = []
        let currentHour = Calendar.current.component(.hour, from: now)
        for entry in today?.hourly ?? [] {
            guard hourly.count < 3 else { break }
            // wttr.in hourly `time` is minutes-of-day as a string: "0", "300", … "2100".
            guard let raw = entry.time, let minutes = Int(raw), minutes / 100 >= currentHour,
                  let temp = entry.tempC.flatMap(Double.init) else { continue }
            let entryKind = WeatherKind.fromWWO(entry.weatherCode.flatMap(Int.init) ?? -1)
            hourly.append((
                time: String(format: "%02d:00", minutes / 100),
                temp: temp,
                icon: entryKind.symbol(isDay: isDay)
            ))
        }

        var days: [DailyForecast] = []
        for entry in payload.weather ?? [] {
            guard let date = entry.date,
                  let high = entry.maxtempC.flatMap(Double.init),
                  let low = entry.mintempC.flatMap(Double.init) else { continue }
            // No per-day condition code in wttr.in — use the midday hourly slot.
            let midday = entry.hourly?.first { $0.time == "1200" } ?? entry.hourly?.first
            let dayKind = WeatherKind.fromWWO(midday?.weatherCode.flatMap(Int.init) ?? -1)
            days.append(DailyForecast(date: date, kind: dayKind, high: high, low: low))
        }

        return WeatherSnapshot(
            temperature: Double(current.tempC) ?? 0,
            feelsLike: current.feelsLikeC.flatMap(Double.init) ?? Double(current.tempC) ?? 0,
            highTemp: today?.maxtempC.flatMap(Double.init) ?? 0,
            lowTemp: today?.mintempC.flatMap(Double.init) ?? 0,
            humidity: current.humidity.flatMap(Int.init) ?? 0,
            windSpeed: current.windspeedKmph.flatMap(Double.init) ?? 0,
            kind: kind,
            isDay: isDay,
            cityName: payload.nearestArea?.first?.preferredName,
            hourly: hourly,
            days: days
        )
    }
}
