import Foundation
@testable import NemoNotch
import Testing

struct WeatherKindTests {
    @Test func wmoCodesMapToKinds() {
        #expect(WeatherKind.fromWMO(0) == .clear)
        #expect(WeatherKind.fromWMO(2) == .partlyCloudy)
        #expect(WeatherKind.fromWMO(3) == .overcast)
        #expect(WeatherKind.fromWMO(48) == .fog)
        #expect(WeatherKind.fromWMO(55) == .drizzle)
        #expect(WeatherKind.fromWMO(66) == .freezingRain)
        #expect(WeatherKind.fromWMO(63) == .rain)
        #expect(WeatherKind.fromWMO(75) == .snow)
        #expect(WeatherKind.fromWMO(82) == .showers)
        #expect(WeatherKind.fromWMO(95) == .thunderstorm)
        #expect(WeatherKind.fromWMO(42) == .cloudy) // unmapped code
    }

    @Test func wwoCodesMapToKinds() {
        #expect(WeatherKind.fromWWO(113) == .clear)
        #expect(WeatherKind.fromWWO(116) == .partlyCloudy)
        #expect(WeatherKind.fromWWO(122) == .overcast)
        #expect(WeatherKind.fromWWO(260) == .fog)
        #expect(WeatherKind.fromWWO(296) == .rain)
        #expect(WeatherKind.fromWWO(356) == .showers)
        #expect(WeatherKind.fromWWO(314) == .freezingRain)
        #expect(WeatherKind.fromWWO(320) == .sleet)
        #expect(WeatherKind.fromWWO(338) == .snow)
        #expect(WeatherKind.fromWWO(389) == .thunderstorm)
        #expect(WeatherKind.fromWWO(-1) == .cloudy) // unmapped code
    }

    @Test func symbolsSwapForNight() {
        #expect(WeatherKind.clear.symbol(isDay: true) == "sun.max.fill")
        #expect(WeatherKind.clear.symbol(isDay: false) == "moon.stars.fill")
        #expect(WeatherKind.partlyCloudy.symbol(isDay: true) == "cloud.sun.fill")
        #expect(WeatherKind.partlyCloudy.symbol(isDay: false) == "cloud.moon.fill")
        #expect(WeatherKind.showers.symbol(isDay: false) == "cloud.moon.rain.fill")
        // Day-invariant kinds keep one symbol.
        #expect(WeatherKind.rain.symbol(isDay: true) == WeatherKind.rain.symbol(isDay: false))
        #expect(WeatherKind.overcast.symbol(isDay: false) == "cloud.fill")
    }
}

struct WeatherParserTests {
    private static let openMeteoJSON = Data(
        """
        {
          "latitude": 31.2,
          "longitude": 121.5,
          "utc_offset_seconds": 28800,
          "current": {
            "time": "2026-07-12T15:10",
            "temperature_2m": 31.4,
            "apparent_temperature": 35.2,
            "relative_humidity_2m": 68,
            "wind_speed_10m": 12.3,
            "weather_code": 80,
            "is_day": 1
          },
          "hourly": {
            "time": ["2026-07-12T14:00", "2026-07-12T15:00", "2026-07-12T16:00", "2026-07-12T17:00", "2026-07-12T18:00"],
            "temperature_2m": [30.9, 31.4, 31.0, 30.2, 29.5],
            "weather_code": [3, 80, 61, 95, 0]
          },
          "daily": {
            "time": ["2026-07-12", "2026-07-13", "2026-07-14"],
            "temperature_2m_max": [33.1, 34.0, 30.5],
            "temperature_2m_min": [27.4, 27.9, 25.1],
            "weather_code": [80, 0, 61]
          }
        }
        """.utf8
    )

    /// 2026-07-12 15:10 in the fixture's UTC+8 zone.
    private static var openMeteoNow: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28800)!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 15, minute: 10))!
    }

    @Test func parsesOpenMeteoCurrentConditions() throws {
        let snapshot = try WeatherParser.parseOpenMeteo(data: Self.openMeteoJSON, now: Self.openMeteoNow)
        #expect(snapshot.temperature == 31.4)
        #expect(snapshot.feelsLike == 35.2)
        #expect(snapshot.humidity == 68)
        #expect(snapshot.windSpeed == 12.3)
        #expect(snapshot.highTemp == 33.1)
        #expect(snapshot.lowTemp == 27.4)
        #expect(snapshot.kind == .showers)
        #expect(snapshot.isDay)
        #expect(snapshot.cityName == nil)
    }

    @Test func openMeteoHourlyStartsAtNowAndCapsAtThree() throws {
        let snapshot = try WeatherParser.parseOpenMeteo(data: Self.openMeteoJSON, now: Self.openMeteoNow)
        #expect(snapshot.hourly.count == 3)
        #expect(snapshot.hourly[0].time == "16:00")
        #expect(snapshot.hourly[0].temp == 31.0)
        #expect(snapshot.hourly[0].icon == "cloud.rain.fill")
        #expect(snapshot.hourly[1].icon == "cloud.bolt.rain.fill")
        #expect(snapshot.hourly[2].icon == "sun.max.fill")
    }

    @Test func openMeteoDailyForecastParsesAllDays() throws {
        let snapshot = try WeatherParser.parseOpenMeteo(data: Self.openMeteoJSON, now: Self.openMeteoNow)
        #expect(snapshot.days == [
            DailyForecast(date: "2026-07-12", kind: .showers, high: 33.1, low: 27.4),
            DailyForecast(date: "2026-07-13", kind: .clear, high: 34.0, low: 27.9),
            DailyForecast(date: "2026-07-14", kind: .rain, high: 30.5, low: 25.1),
        ])
    }

    private static let wttrJSON = Data(
        """
        {
          "current_condition": [{
            "temp_C": "8",
            "FeelsLikeC": "5",
            "humidity": "81",
            "windspeedKmph": "19",
            "weatherCode": "296"
          }],
          "weather": [{
            "date": "2026-03-05",
            "maxtempC": "10",
            "mintempC": "4",
            "hourly": [
              {"time": "0", "tempC": "5", "weatherCode": "119"},
              {"time": "1200", "tempC": "9", "weatherCode": "296"},
              {"time": "1500", "tempC": "10", "weatherCode": "353"},
              {"time": "2100", "tempC": "6", "weatherCode": "113"}
            ]
          }, {
            "date": "2026-03-06",
            "maxtempC": "12",
            "mintempC": "5",
            "hourly": [
              {"time": "1200", "tempC": "11", "weatherCode": "113"}
            ]
          }],
          "nearest_area": [{
            "areaName": [{"value": "Shanghai"}],
            "region": [{"value": "Shanghai Shi"}],
            "country": [{"value": "China"}]
          }]
        }
        """.utf8
    )

    /// A date whose local hour is 11, so the hourly filter is deterministic.
    private static var wttrNow: Date {
        Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
    }

    @Test func parsesWTTRCurrentConditions() throws {
        let snapshot = try WeatherParser.parseWTTR(data: Self.wttrJSON, now: Self.wttrNow)
        #expect(snapshot.temperature == 8)
        #expect(snapshot.feelsLike == 5)
        #expect(snapshot.humidity == 81)
        #expect(snapshot.windSpeed == 19)
        #expect(snapshot.highTemp == 10)
        #expect(snapshot.lowTemp == 4)
        #expect(snapshot.kind == .rain)
        #expect(snapshot.isDay) // `isday` absent → defaults to day
        #expect(snapshot.cityName == "Shanghai")
    }

    @Test func wttrHourlySkipsPastHours() throws {
        let snapshot = try WeatherParser.parseWTTR(data: Self.wttrJSON, now: Self.wttrNow)
        #expect(snapshot.hourly.count == 3)
        #expect(snapshot.hourly[0].time == "12:00")
        #expect(snapshot.hourly[0].temp == 9)
        #expect(snapshot.hourly[0].icon == "cloud.rain.fill")
        #expect(snapshot.hourly[1].icon == "cloud.sun.rain.fill")
        #expect(snapshot.hourly[2].time == "21:00")
    }

    @Test func wttrDailyForecastUsesMiddayCondition() throws {
        let snapshot = try WeatherParser.parseWTTR(data: Self.wttrJSON, now: Self.wttrNow)
        #expect(snapshot.days == [
            DailyForecast(date: "2026-03-05", kind: .rain, high: 10, low: 4),
            DailyForecast(date: "2026-03-06", kind: .clear, high: 12, low: 5),
        ])
    }

    @Test func dailyForecastLabelsTodayDistinctly() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let today = DailyForecast(date: formatter.string(from: now), kind: .clear, high: 1, low: 0)
        let tomorrow = DailyForecast(
            date: formatter.string(from: now.addingTimeInterval(86400)),
            kind: .clear,
            high: 1,
            low: 0
        )
        #expect(today.label(now: now) != tomorrow.label(now: now))
        #expect(tomorrow.label(now: now) != tomorrow.date) // weekday, not the raw date
        // Unparseable date falls back to the raw string.
        let broken = DailyForecast(date: "not-a-date", kind: .clear, high: 1, low: 0)
        #expect(broken.label(now: now) == "not-a-date")
    }

    @Test func wttrWithoutCurrentConditionThrows() {
        let empty = Data(#"{"current_condition": []}"#.utf8)
        #expect(throws: WeatherParseError.self) {
            _ = try WeatherParser.parseWTTR(data: empty)
        }
    }
}
