import EventKit
import SwiftUI

// MARK: - OverviewTab

struct OverviewTab: View {
    @Environment(MediaService.self) var mediaService

    private var hasTrack: Bool { !mediaService.playbackState.isEmpty }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            let numGaps: CGFloat = hasTrack ? 2 : 1
            let totalCardWidth = geo.size.width - gap * numGaps

            let calendarWidth = totalCardWidth * (hasTrack ? 2.0 / 5.0 : 2.0 / 3.0)
            let mediaWidth = totalCardWidth * 2.0 / 5.0
            let weatherWidth = totalCardWidth * (hasTrack ? 1.0 / 5.0 : 1.0 / 3.0)

            HStack(alignment: .top, spacing: gap) {
                OverviewCalendarSection()
                    .frame(width: calendarWidth)

                if hasTrack {
                    OverviewMediaSection()
                        .frame(width: mediaWidth)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .leading)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .trailing))
                        ))
                }

                OverviewWeatherSection()
                    .frame(width: weatherWidth)
            }
            .animation(.spring(duration: 0.3, bounce: 0.05), value: hasTrack)
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Calendar Section

private struct OverviewCalendarSection: View {
    @Environment(CalendarService.self) var calendarService
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        Group {
            switch calendarService.authorizationStatus {
            case .fullAccess:
                calendarContent
            default:
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.lock")
                        .font(.system(size: 20))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("calendar.permission_required")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            Text(calendarService.monthLabel(locale: appSettings.currentLocale))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            DateStripView(
                dates: calendarService.dateRange,
                selectedDate: calendarService.selectedDate,
                hasEvents: { calendarService.hasEvents(on: $0) },
                onSelect: { calendarService.selectedDate = $0 },
                locale: appSettings.currentLocale
            )
            .padding(.vertical, 2)
            .padding(.horizontal, 4)

            Divider()
                .background(NotchTheme.stroke)
                .padding(.vertical, 2)

            eventList
        }
    }

    private var eventList: some View {
        let events = calendarService.eventsForSelectedDate
        return Group {
            if events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("calendar.no_events")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(events) { event in
                            CalendarEventRow(event: event)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .notchScrollEdgeShadow(.vertical, thickness: 10, intensity: 0.36)
            }
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(cgColor: event.calendarColor))
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted : NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(eventTimeRange)
                    .font(.system(size: 9))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted.opacity(0.75) : NotchTheme.textSecondary)
            }

            Spacer(minLength: 0)

            if event.meetingURL != nil {
                CalendarMeetingIcon(platform: event.meetingPlatform)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && event.meetingURL != nil ? NotchTheme.surfaceEmphasis : NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isHovered && event.meetingURL != nil ? NotchTheme.accent.opacity(0.4) : NotchTheme.stroke,
                            lineWidth: 0.6
                        )
                )
        )
        .opacity(event.meetingURL != nil ? 1 : event.isPast ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            if event.meetingURL != nil { isHovered = hovering }
        }
        .onTapGesture {
            if let url = event.meetingURL { NSWorkspace.shared.open(url) }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var eventTimeRange: String {
        if event.isAllDay { return String(localized: "calendar.all_day") }
        return "\(Self.timeFormatter.string(from: event.startDate)) - \(Self.timeFormatter.string(from: event.endDate))"
    }
}

private struct CalendarMeetingIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        Circle()
            .fill(platform.iconColor.opacity(0.2))
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: platform.iconName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(platform.iconColor)
            )
    }
}

// MARK: - Media Section

private struct OverviewMediaSection: View {
    @Environment(MediaService.self) var mediaService

    private var state: PlaybackState { mediaService.playbackState }

    var body: some View {
        VStack(spacing: 6) {
            if let denied = mediaService.permissionDeniedPlayer {
                permissionBanner(player: denied)
            } else {
                artwork
                trackInfo
                progressBar
                controls
            }
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .center)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private func permissionBanner(player: KnownPlayer) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20))
                .foregroundStyle(NotchTheme.accent)
            Text("\(player.displayName) 自动化权限被拒绝")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("在 系统设置 → 隐私与安全 → 自动化 中开启")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 6) {
                Button("打开设置") { mediaService.openAutomationSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(NotchTheme.accent))
                    .foregroundStyle(Color.black.opacity(0.85))

                Button("忽略") { mediaService.dismissPermissionBanner() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            VinylDiscView(
                isPlaying: state.isPlaying,
                artworkData: state.artworkData,
                appIcon: mediaService.appIcon,
                size: 80
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            if let appIcon = mediaService.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(height: 80)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Text(state.artist)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressBar: some View {
        VStack(spacing: 5) {
            ProgressScrubber(
                position: state.position,
                duration: state.duration,
                enabled: mediaService.supportsSeeking,
                onScrub: { fraction in mediaService.seek(toFraction: fraction) }
            )
            .frame(height: 12)

            HStack {
                Text(formatTime(state.position))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer()
                Text(formatTime(state.duration))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private var controls: some View {
        let canSeek = mediaService.supportsSeeking
        return HStack(spacing: canSeek ? 10 : 14) {
            Button(action: { mediaService.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: canSeek ? 11 : 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)

            if canSeek {
                Button(action: { mediaService.skipBackward() }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 13))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: { mediaService.togglePlayPause() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(NotchTheme.accent))
            }
            .buttonStyle(.plain)

            if canSeek {
                Button(action: { mediaService.skipForward() }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 13))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: { mediaService.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: canSeek ? 11 : 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time > 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

// MARK: - Progress Scrubber

private struct ProgressScrubber: View {
    let position: Double
    let duration: Double
    let enabled: Bool
    let onScrub: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var isHovering = false

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let barHeight: CGFloat = (isHovering || dragFraction != nil) ? 6 : 4
            ZStack(alignment: .leading) {
                Color.clear // hit area
                Capsule()
                    .fill(NotchTheme.surfaceEmphasis)
                    .frame(height: barHeight)
                Capsule()
                    .fill(NotchTheme.accent.opacity(0.85))
                    .frame(width: geo.size.width * CGFloat(fraction), height: barHeight)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: barHeight)
            .onHover { hovering in
                guard enabled else { return }
                isHovering = hovering
            }
            .gesture(
                enabled
                    ? DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                            dragFraction = f
                        }
                        .onEnded { _ in
                            if let f = dragFraction { onScrub(f) }
                            dragFraction = nil
                        }
                    : nil
            )
        }
    }
}

// MARK: - Weather Section

private struct OverviewWeatherSection: View {
    @Environment(WeatherService.self) var weatherService

    var body: some View {
        Group {
            if !weatherService.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .tint(NotchTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                weatherContent
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weatherService.cityName)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)

            HStack(spacing: 2) {
                Image(systemName: conditionIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("\(Int(weatherService.temperature))°")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
            }

            Text(weatherService.condition)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)

            Divider()
                .background(NotchTheme.stroke)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            VStack(spacing: 4) {
                statItem(label: String(localized: "weather.feels_like"), value: "\(Int(weatherService.feelsLike))°")
                statItem(label: String(localized: "weather.humidity"), value: "\(weatherService.humidity)%")
                statItem(label: String(localized: "weather.wind_speed"), value: "\(Int(weatherService.windSpeed))km/h")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func statItem(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    private var conditionIcon: String {
        let lower = weatherService.condition.lowercased()
        if lower.contains("sunny") || lower.contains("clear") { return "sun.max.fill" }
        if lower.contains("partly cloudy") { return "cloud.sun.fill" }
        if lower.contains("cloudy") || lower.contains("overcast") { return "cloud.fill" }
        if lower.contains("rain") || lower.contains("drizzle") { return "cloud.rain.fill" }
        if lower.contains("snow") { return "snowflake" }
        if lower.contains("thunder") { return "cloud.bolt.fill" }
        if lower.contains("fog") || lower.contains("mist") { return "cloud.fog.fill" }
        return "cloud.sun.fill"
    }
}
