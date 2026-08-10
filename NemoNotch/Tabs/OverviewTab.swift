import EventKit
import SwiftUI

// MARK: - OverviewTab

struct OverviewTab: View {
    @Environment(MediaService.self) var mediaService

    private var hasTrack: Bool {
        !mediaService.playbackState.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            let numGaps: CGFloat = hasTrack ? 2 : 1
            let totalCardWidth = geo.size.width - gap * numGaps

            let calendarWidth = totalCardWidth * (hasTrack ? 1.8 / 5.0 : 2.0 / 3.0)
            let mediaWidth = totalCardWidth * 2.0 / 5.0
            let weatherWidth = totalCardWidth * (hasTrack ? 1.2 / 5.0 : 1.0 / 3.0)

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
                PermissionCard(
                    icon: "calendar.badge.lock",
                    titleKey: "permission.calendar.title",
                    detailKey: "permission.calendar.detail",
                    status: calendarService.authorizationStatus == .denied
                        ? .denied
                        : .notDetermined,
                    primary: .programmatic { calendarService.requestAccess() },
                    openSettings: { calendarService.openSystemSettings() }
                )
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
            if event.meetingURL != nil {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if let url = event.meetingURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var eventTimeRange: String {
        if event.isAllDay {
            return String(localized: "calendar.all_day")
        }
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

    private var state: PlaybackState {
        mediaService.playbackState
    }

    /// Album-derived accent tinting the glow, scrubber, and play button;
    /// falls back to the theme accent for grayscale / missing artwork.
    private var accent: Color {
        mediaService.artworkAccent ?? NotchTheme.accent
    }

    /// Vinyl diameter. The halo's radius is derived from it so the two can't
    /// drift apart.
    private static let discSize: CGFloat = 80
    /// How far the halo reaches past the vinyl, as a multiple of its radius.
    /// 1.6 spills ~24pt beyond an 80pt disc — enough to read as light rather
    /// than as an outline.
    private static let haloScale: CGFloat = 1.6

    var body: some View {
        VStack(spacing: 6) {
            artwork
            trackInfo
            progressBar
            controls
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .center)
        .notchCard(radius: 8, fill: NotchTheme.surface)
        .onAppear { showsSeekButtons = mediaService.supportsSeeking }
        .onChange(of: mediaService.supportsSeeking) { _, canSeek in
            updateSeekVisibility(canSeek)
        }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            VinylDiscView(
                isPlaying: state.isPlaying,
                artworkData: state.artworkData,
                appIcon: mediaService.appIcon,
                size: Self.discSize
            )
            .background {
                // Mood-light halo behind the vinyl in the album's dominant
                // color — bright while playing, embers when paused.
                //
                // A radial falloff, not a blurred disc: the old
                // Circle().fill().blur(14) was scaled only 1.12, so the opaque
                // vinyl covered everything except a hard smudged rim. The
                // stops ease out (rather than fading linearly) so the spill
                // has no banding, and dropping the blur also drops an
                // offscreen render pass.
                RadialGradient(
                    stops: [
                        .init(color: accent, location: 0.45),
                        .init(color: accent.opacity(0.5), location: 0.72),
                        .init(color: accent.opacity(0), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: Self.discSize / 2
                )
                .scaleEffect(Self.haloScale)
                .opacity(state.isPlaying ? 0.5 : 0.14)
                .animation(.easeInOut(duration: 0.6), value: state.isPlaying)
                .animation(.easeInOut(duration: 0.6), value: accent)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            if let appIcon = mediaService.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: 2, y: 2)
                    .onTapGesture {
                        if let bundleID = state.appBundleIdentifier,
                           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
            }
        }
        .frame(height: Self.discSize)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeText(
                text: state.title,
                font: .system(size: 11, weight: .semibold),
                color: NotchTheme.textPrimary
            )
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
                position: mediaService.playbackPosition,
                duration: state.duration,
                enabled: mediaService.supportsSeeking,
                tint: accent,
                onScrub: { fraction in mediaService.seek(toFraction: fraction) }
            )
            .frame(height: 12)
            .animation(.easeInOut(duration: 0.6), value: accent)

            HStack {
                // 动画绑格式化后的字符串，而不是 playbackPosition 本身：进度每
                // 0.5s 推进一次，但这个标签是秒级的，所以有一半的推进显示值没
                // 变。绑上游数值会让 numericText 在每次推进时都跑一段 0.25s 动
                // 画（展开态下约一半时间都在动画中），其中一半是空转。
                let elapsed = formatTime(mediaService.playbackPosition)
                Text(elapsed)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: elapsed)
                Spacer()
                Text(formatTime(state.duration))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    @State private var prevNudge: CGFloat = 0
    @State private var nextNudge: CGFloat = 0
    @State private var backWiggle: Double = 0
    @State private var forwardWiggle: Double = 0

    /// Debounced `supportsSeeking` for the seek buttons' structural presence.
    /// During a track change the CLI briefly reports duration 0, which would
    /// remove and re-insert the ±15s buttons (a visible flash). Turning on is
    /// immediate; turning off requires the unseekable state to persist.
    @State private var showsSeekButtons = false
    @State private var seekDropTask: Task<Void, Never>?

    private func updateSeekVisibility(_ canSeek: Bool) {
        seekDropTask?.cancel()
        seekDropTask = nil
        if canSeek {
            showsSeekButtons = true
        } else {
            seekDropTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                showsSeekButtons = false
            }
        }
    }

    private var controls: some View {
        let canSeek = showsSeekButtons
        return HStack(spacing: canSeek ? 6 : 10) {
            Button(action: {
                nudge($prevNudge, toward: -3)
                mediaService.previousTrack()
            }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .offset(x: prevNudge)

            if canSeek {
                Button(action: {
                    wiggle($backWiggle, degrees: -11)
                    mediaService.skipBackward()
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(backWiggle))
            }

            Button(action: { mediaService.togglePlayPause() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: state.isPlaying)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(accent))
                    .animation(.easeInOut(duration: 0.6), value: accent)
            }
            .buttonStyle(.plain)

            if canSeek {
                Button(action: {
                    wiggle($forwardWiggle, degrees: 11)
                    mediaService.skipForward()
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(forwardWiggle))
            }

            Button(action: {
                nudge($nextNudge, toward: 3)
                mediaService.nextTrack()
            }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .offset(x: nextNudge)
        }
    }

    // Press micro-interactions (Atoll's nudge/wiggle springs): track-change
    // buttons shove briefly toward the skip direction, seek buttons twitch a
    // few degrees and settle back.

    private func nudge(_ offset: Binding<CGFloat>, toward amount: CGFloat) {
        withAnimation(.spring(response: 0.16, dampingFraction: 0.72)) {
            offset.wrappedValue = amount
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                offset.wrappedValue = 0
            }
        }
    }

    private func wiggle(_ angle: Binding<Double>, degrees: Double) {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.52)) {
            angle.wrappedValue = degrees
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                angle.wrappedValue = 0
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
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
    var tint: Color = NotchTheme.accent
    let onScrub: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var isHovering = false

    private var fraction: Double {
        if let dragFraction {
            return dragFraction
        }
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    var body: some View {
        GeometryReader { geo in
            // Three-tier track thickness: resting → hover → actively dragging
            // (the extra step plus the bouncy settle makes the grab feel
            // physical, à la Atoll's slider).
            let barHeight: CGFloat = dragFraction != nil ? 9 : (isHovering ? 6 : 4)
            ZStack(alignment: .leading) {
                Color.clear // hit area
                Capsule()
                    .fill(NotchTheme.surfaceEmphasis)
                    .frame(height: barHeight)
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: geo.size.width * CGFloat(fraction), height: barHeight)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.bouncy.speed(1.4), value: barHeight)
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
                        if let f = dragFraction {
                            onScrub(f)
                        }
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
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        Group {
            if !appSettings.weatherCity.isEmpty || weatherService.locationAuthorizationStatus == .authorizedAlways {
                if !weatherService.isLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .tint(NotchTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    weatherContent
                }
            } else {
                PermissionCard(
                    icon: "location.slash",
                    titleKey: "permission.location.title",
                    detailKey: "permission.location.detail",
                    status: weatherService.locationAuthorizationStatus == .denied
                        ? .denied
                        : .notDetermined,
                    primary: .programmatic { weatherService.requestLocationAccess() },
                    openSettings: { weatherService.openLocationSettings() }
                )
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
        .activates(weatherService)
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weatherService.cityName)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)

            HStack(spacing: 2) {
                Image(systemName: weatherService.symbolName)
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

            if !weatherService.dailyForecast.isEmpty {
                Divider()
                    .background(NotchTheme.stroke)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(weatherService.dailyForecast, id: \.date) { day in
                            dailyRow(day)
                        }
                    }
                }
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

    private func dailyRow(_ day: DailyForecast) -> some View {
        HStack(spacing: 4) {
            Text(day.label())
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
                .frame(width: 28, alignment: .leading)
            Image(systemName: day.kind.symbol(isDay: true))
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 0)
            Text("\(Int(day.high))°/\(Int(day.low))°")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
    }
}
