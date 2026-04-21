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
                .tint(.white.opacity(0.5))
            Text("加载中...")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
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
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: conditionIcon)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.8))
            Text("\(Int(weatherService.temperature))°")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var conditionRow: some View {
        HStack {
            Text(weatherService.condition)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("H:\(Int(weatherService.highTemp))°  L:\(Int(weatherService.lowTemp))°")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.08))
        )
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    private var hourlyForecastRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weatherService.hourlyForecast.enumerated()), id: \.offset) { index, hour in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.06))
                        .frame(width: 1, height: 30)
                }
                VStack(spacing: 3) {
                    Text(hour.time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Image(systemName: iconForCondition(hour.icon))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(Int(hour.temp))°")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.08))
        )
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
