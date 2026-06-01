import AppKit
import EventKit
import Foundation

/// UI 测试/截图模式下,把各 @Observable service 填成营销级活跃态。
/// 仅在 `UITestMode.isActive` 时由 AppDelegate 调用。
@MainActor
enum UITestSeeder {
    /// 临时 tasks 文件,避免污染 ~/.NemoNotch/tasks.json。
    static let tasksURL = URL(fileURLWithPath: "/tmp/nemonotch-uitest-tasks.json")

    static func seed(
        media: MediaService,
        calendar: CalendarService,
        weather: WeatherService,
        system: SystemService,
        aiStore: AISessionStore,
        registry: AgentMonitorRegistry,
        pomodoro: PomodoroTimerService,
        tasks: TaskStore
    ) {
        seedMedia(media)
        seedCalendar(calendar)
        seedWeather(weather)
        seedSystem(system)
        seedAI(aiStore)
        seedAgents(registry)
        seedPomodoro(pomodoro, tasks: tasks)
    }

    // MARK: - Overview: media + calendar + weather

    private static func seedMedia(_ media: MediaService) {
        var s = PlaybackState()
        s.title = "Midnight City"
        s.artist = "M83"
        s.album = "Hurry Up, We're Dreaming"
        s.duration = 244
        s.position = 96
        s.isPlaying = true
        s.appName = "Music"
        // 故意不设 KnownPlayer bundle id:否则 Overview 会因缺少 Automation 授权
        // 渲染权限卡而非正在播放卡。留空走 MediaRemote 路径,直接显示 now-playing。
        s.appBundleIdentifier = nil
        s.artworkData = makeArtwork(
            top: NSColor(red: 0.42, green: 0.20, blue: 0.62, alpha: 1),
            bottom: NSColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1),
            glyph: "♪"
        )
        media.playbackState = s
    }

    private static func seedCalendar(_ calendar: CalendarService) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
        let blue = NSColor.systemBlue.cgColor
        let green = NSColor.systemGreen.cgColor
        let orange = NSColor.systemOrange.cgColor
        let events: [CalendarEvent] = [
            CalendarEvent(
                title: "Standup",
                startDate: at(10, 0),
                endDate: at(10, 15),
                calendarColor: blue,
                isAllDay: false,
                url: URL(string: "https://meet.google.com/abc-defg-hij")
            ),
            CalendarEvent(
                title: "Design Review",
                startDate: at(14, 0),
                endDate: at(15, 0),
                calendarColor: green,
                isAllDay: false
            ),
            CalendarEvent(
                title: "1:1 with Alex",
                startDate: at(16, 30),
                endDate: at(17, 0),
                calendarColor: orange,
                isAllDay: false
            ),
        ]
        var multi: [Date: [CalendarEvent]] = [today: events]
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            multi[tomorrow] = [
                CalendarEvent(
                    title: "Sprint Planning",
                    startDate: tomorrow,
                    endDate: tomorrow,
                    calendarColor: blue,
                    isAllDay: true
                ),
            ]
        }
        calendar.seedForUITest(events: multi)
    }

    private static func seedWeather(_ weather: WeatherService) {
        weather.cityName = "San Francisco"
        weather.condition = "Partly Cloudy"
        weather.temperature = 21
        weather.feelsLike = 20
        weather.highTemp = 24
        weather.lowTemp = 15
        weather.humidity = 62
        weather.windSpeed = 12
        weather.hourlyForecast = [
            ("15:00", 22, "Sunny"),
            ("16:00", 21, "Partly Cloudy"),
            ("17:00", 19, "Cloudy"),
        ]
        weather.isLoaded = true
    }

    // MARK: - System

    private static func seedSystem(_ system: SystemService) {
        func icon(_ bundleID: String) -> NSImage? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let procs: [ProcessEntry] = [
            ProcessEntry(
                id: 101,
                displayName: "Xcode",
                icon: icon("com.apple.dt.Xcode"),
                cpuUsage: 184.2,
                memoryUsed: 4_820_000_000
            ),
            ProcessEntry(
                id: 102,
                displayName: "Google Chrome",
                icon: icon("com.google.Chrome"),
                cpuUsage: 62.5,
                memoryUsed: 2_140_000_000
            ),
            ProcessEntry(
                id: 103,
                displayName: "Figma",
                icon: icon("com.figma.Desktop"),
                cpuUsage: 38.1,
                memoryUsed: 1_360_000_000
            ),
            ProcessEntry(
                id: 104,
                displayName: "Slack",
                icon: icon("com.tinyspeck.slackmacgap"),
                cpuUsage: 12.7,
                memoryUsed: 880_000_000
            ),
            ProcessEntry(
                id: 105,
                displayName: "Terminal",
                icon: icon("com.apple.Terminal"),
                cpuUsage: 6.3,
                memoryUsed: 210_000_000
            ),
        ]
        system.topProcessesByCPU = procs
        system.topProcessesByMemory = procs.sorted { $0.memoryUsed > $1.memoryUsed }
        system.cpuUsage = 42
        system.memoryTotal = 16_000_000_000
        system.memoryUsed = 11_200_000_000
        system.batteryLevel = 76
        system.isCharging = true
        system.diskTotal = 1_000_000_000_000
        system.diskFree = 412_000_000_000
        system.uploadSpeed = 11100
        system.downloadSpeed = 38900
    }

    // MARK: - AI Chat

    private static func seedAI(_ store: AISessionStore) {
        // 清掉真实扫描到的会话,确保种子会话成为 activeSession。
        store.removeAll(source: .claude)
        store.removeAll(source: .gemini)

        let sid = "uitest-claude-session"
        store.mutateOrCreate(sid, source: .claude) { s in
            s.cwd = "/Users/dev/Projects/NemoNotch"
            s.model = "claude-opus-4-8"
            s.phase = .processing
            s.firstUserMessage = "Add a pomodoro timer to the notch panel"
            s.lastUserMessage = "Add a pomodoro timer to the notch panel"
            s.inputTokens = 18400
            s.outputTokens = 6220
            s.cacheReadTokens = 142_000
            s.cacheCreationTokens = 9800
            s.lastContextTokens = 96500
            s.currentTool = "Edit"
            s.messages = [
                ChatMessage(
                    id: "m1",
                    role: .user,
                    content: "Add a pomodoro timer to the notch panel"
                ),
                ChatMessage(
                    id: "m2",
                    role: .assistant,
                    content: "I'll add a PomodoroTimerService with a 25/5/15 cycle and wire it into a new tab."
                ),
                ChatMessage(
                    id: "m3",
                    role: .assistant,
                    content: "",
                    toolName: "Edit",
                    toolInput: "NemoNotch/Services/PomodoroTimerService.swift"
                ),
                ChatMessage(id: "m4", role: .toolResult, content: "Applied 1 edit to PomodoroTimerService.swift"),
                ChatMessage(
                    id: "m5",
                    role: .assistant,
                    content: "Done. The timer ticks every second and pulses the notch ring on phase end."
                ),
            ]
        }
        store.selectedSessionId = sid
    }

    // MARK: - Agents

    private static func seedAgents(_ registry: AgentMonitorRegistry) {
        let hermes = UITestMockAgentMonitor(
            displayName: "Hermes",
            iconEmoji: "🪽",
            agents: [
                MonitoredAgent(
                    id: "h1",
                    name: "researcher",
                    emoji: "🔎",
                    state: .working,
                    currentTool: "WebSearch",
                    lastMessage: "Comparing 3 charting libraries…",
                    workspace: "/Users/dev/Projects/dashboard",
                    lastEventTime: Date().addingTimeInterval(-30)
                ),
            ]
        )
        let openClaw = UITestMockAgentMonitor(
            displayName: "OpenClaw",
            iconEmoji: "🦞",
            agents: [
                MonitoredAgent(
                    id: "o1",
                    name: "builder",
                    emoji: "🔨",
                    state: .toolCalling,
                    currentTool: "Bash",
                    lastMessage: "Running the test suite…",
                    workspace: "/Users/dev/Projects/api",
                    lastEventTime: Date().addingTimeInterval(-12)
                ),
            ]
        )
        registry.register(hermes)
        registry.register(openClaw)
    }

    // MARK: - Pomodoro

    private static func seedPomodoro(_ pomodoro: PomodoroTimerService, tasks: TaskStore) {
        let t1 = tasks.add(
            title: "Ship uitest screenshots",
            priority: .high,
            notes: "",
            tags: ["nemonotch"],
            dueDate: nil
        )
        tasks.update(t1) { $0.completedPomodoros = 3 }
        let t2 = tasks.add(
            title: "Update README",
            priority: .medium,
            notes: "",
            tags: ["docs"],
            dueDate: nil
        )
        tasks.update(t2) { $0.completedPomodoros = 1 }
        let t3 = tasks.add(
            title: "Review PR #42",
            priority: .low,
            notes: "",
            tags: [],
            dueDate: nil
        )
        tasks.update(t3) { $0.completedPomodoros = 0 }
        // 进行中的工作番茄,active pie 立即可见。
        pomodoro.start(taskID: t1, duration: 25 * 60, autoFlow: false)
    }

    // MARK: - 截图矩形落盘(供脚本读取)

    /// 把指定屏上、给定 Tab 的面板内容矩形写到 rectFilePath,
    /// 坐标为 screencapture 习惯(原点=主屏左上,y 向下),单位点。
    static func writeCaptureRect(for tab: Tab, on screen: NSScreen) {
        let width: CGFloat = (tab == .overview) ? NotchConstants.overviewOpenedWidth : NotchConstants.openedWidth
        let height: CGFloat = NotchConstants.openedHeight
        let x = screen.frame.midX - width / 2
        let y: CGFloat = 0 // 面板从刘海顶端下垂,内容顶 = 屏顶
        let line = "\(Int(x)) \(Int(y)) \(Int(width)) \(Int(height))\n"
        try? line.write(toFile: UITestMode.rectFilePath, atomically: true, encoding: .utf8)
    }

    // MARK: - 示例封面图(纯绘制,无版权素材)

    private static func makeArtwork(top: NSColor, bottom: NSColor, glyph: String) -> Data? {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(starting: top, ending: bottom)
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 150, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: glyph, attributes: attrs)
        let textSize = str.size()
        str.draw(at: NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        ))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
