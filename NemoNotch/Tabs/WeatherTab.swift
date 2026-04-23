import SwiftUI

struct WeatherTab: View {
    @Environment(WeatherService.self) var weatherService

    var body: some View {
        if !weatherService.isLoaded {
            loadingState
        } else {
            weatherContent
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(NotchTheme.textSecondary)
            Text("加载中...")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weatherContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                headerRow
                conditionRow
                statsRow
                hourlyForecastRow
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text(weatherService.cityName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: conditionIcon)
                .font(.system(size: 20))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("\(Int(weatherService.temperature))°")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
        }
    }

    private var conditionRow: some View {
        HStack {
            Text(weatherService.condition)
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("H:\(Int(weatherService.highTemp))°  L:\(Int(weatherService.lowTemp))°")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(label: "体感", value: "\(Int(weatherService.feelsLike))°")
            Spacer(minLength: 0)
            statItem(label: "湿度", value: "\(weatherService.humidity)%")
            Spacer(minLength: 0)
            statItem(label: "风速", value: "\(Int(weatherService.windSpeed))km/h")
        }
        .padding(.vertical, 8)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var hourlyForecastRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weatherService.hourlyForecast.enumerated()), id: \.offset) { index, hour in
                if index > 0 {
                    Rectangle()
                        .fill(NotchTheme.stroke.opacity(0.7))
                        .frame(width: 1, height: 30)
                }
                VStack(spacing: 3) {
                    Text(hour.time)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Image(systemName: iconForCondition(hour.icon))
                        .font(.system(size: 14))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("\(Int(hour.temp))°")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var conditionIcon: String {
        iconForCondition(weatherService.condition)
    }

    private func iconForCondition(_ condition: String) -> String {
        let lower = condition.lowercased()
        if lower.contains("sunny") || lower.contains("clear") {
            return "sun.max.fill"
        } else if lower.contains("partly cloudy") {
            return "cloud.sun.fill"
        } else if lower.contains("cloudy") || lower.contains("overcast") {
            return "cloud.fill"
        } else if lower.contains("rain") || lower.contains("drizzle") {
            return "cloud.rain.fill"
        } else if lower.contains("snow") {
            return "snowflake"
        } else if lower.contains("thunder") {
            return "cloud.bolt.fill"
        } else if lower.contains("fog") || lower.contains("mist") {
            return "cloud.fog.fill"
        } else {
            return "cloud.sun.fill"
        }
    }
}
