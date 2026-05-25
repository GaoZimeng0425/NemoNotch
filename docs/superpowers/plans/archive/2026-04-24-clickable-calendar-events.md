# Clickable Calendar Events Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make calendar events with meeting URLs clickable — hover shows platform icon, click opens the link.

**Architecture:** Extract URL/location/notes from EKEvent, detect meeting URLs via NSDataDetector, render hover-aware event rows with SF Symbol platform icons + brand-colored dots. Only events with detected URLs are interactive.

**Tech Stack:** SwiftUI, EventKit (EKEvent), NSDataDetector, NSWorkspace

---

### Task 1: Extend CalendarEvent model

**Files:**
- Modify: `NemoNotch/Models/CalendarEvent.swift`

**Step 1: Add new fields to CalendarEvent**

Add `url: URL?`, `location: String?`, `notes: String?` stored properties. Add a computed `meetingURL: URL?` that searches all three fields using `NSDataDetector` for the first URL found.

```swift
import AppKit
import Foundation

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarColor: CGColor
    let isAllDay: Bool
    let url: URL?
    let location: String?
    let notes: String?

    init(
        title: String, startDate: Date, endDate: Date,
        calendarColor: CGColor, isAllDay: Bool,
        url: URL? = nil, location: String? = nil, notes: String? = nil
    ) {
        self.id = "\(title)-\(startDate.timeIntervalSince1970)"
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarColor = calendarColor
        self.isAllDay = isAllDay
        self.url = url
        self.location = location
        self.notes = notes
    }

    var isPast: Bool { endDate < Date() }

    var meetingURL: URL? {
        if let url { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let fields = [location, notes].compactMap { $0 }
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            if let match = detector.firstMatch(in: field, range: range),
               let url = match.url
            {
                return url
            }
        }
        return nil
    }

    var meetingPlatform: MeetingPlatform {
        guard let host = meetingURL?.host?.lowercased() else { return .generic }
        if host.contains("meet.google.com") { return .googleMeet }
        if host.contains("zoom.us") { return .zoom }
        if host.contains("teams.microsoft.com") { return .teams }
        return .generic
    }
}

enum MeetingPlatform {
    case googleMeet, zoom, teams, generic

    var iconName: String {
        switch self {
        case .googleMeet, .zoom, .teams: "video.fill"
        case .generic: "link"
        }
    }

    var iconColor: Color {
        switch self {
        case .googleMeet: Color(red: 0.27, green: 0.53, blue: 0.93)   // Google Blue
        case .zoom: Color(red: 0.36, green: 0.58, blue: 0.89)         // Zoom Blue
        case .teams: Color(red: 0.44, green: 0.29, blue: 0.79)        // Teams Purple
        case .generic: NotchTheme.textTertiary
        }
    }
}
```

**Step 2: Build the project to verify compilation**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (existing callers pass `nil` for new optional params by default)

**Step 3: Commit**

```bash
git add NemoNotch/Models/CalendarEvent.swift
git commit -m "feat(calendar): add url/location/notes fields and meeting URL detection"
```

---

### Task 2: Extract extra fields in CalendarService

**Files:**
- Modify: `NemoNotch/Services/CalendarService.swift:107-113`

**Step 1: Pass EKEvent's url, location, notes into CalendarEvent**

In `fetchEvents()`, update the CalendarEvent initializer to include the three new fields:

```swift
let event = CalendarEvent(
    title: ek.title,
    startDate: ek.startDate,
    endDate: ek.endDate,
    calendarColor: ek.calendar.cgColor,
    isAllDay: ek.isAllDay,
    url: ek.url,
    location: ek.location,
    notes: ek.notes
)
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add NemoNotch/Services/CalendarService.swift
git commit -m "feat(calendar): extract url/location/notes from EKEvent"
```

---

### Task 3: Add clickable event row with hover indicator

**Files:**
- Modify: `NemoNotch/Tabs/CalendarTab.swift:109-137`

**Step 1: Replace eventRow with hover-aware Button version**

Replace the entire `eventRow` function with a version that:
- Wraps content in a `Button` (only when `meetingURL != nil`)
- Tracks hover state via `@State`
- Shows a platform icon (SF Symbol + brand color dot) on hover
- Opens URL via `NSWorkspace.shared.open` on click

```swift
private func eventRow(_ event: CalendarEvent) -> some View {
    let hasURL = event.meetingURL != nil
    return EventRowContent(event: event)
        .overlay(alignment: .trailing) {
            if hasURL {
                MeetingIcon(platform: event.meetingPlatform)
            }
        }
        .opacity(hasURL ? 1 : event.isPast ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = event.meetingURL {
                NSWorkspace.shared.open(url)
            }
        }
}
```

Note: Since `CalendarTab` is a struct, the hover state should be managed in a small helper view. Add these two private helper views inside `CalendarTab.swift`:

```swift
private struct EventRowContent: View {
    let event: CalendarEvent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(cgColor: event.calendarColor))
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted : NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(eventTimeRange(event))
                    .font(.system(size: 10))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted.opacity(0.75) : NotchTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        .onHover { hovering in
            if event.meetingURL != nil {
                isHovered = hovering
            }
        }
    }

    private func eventTimeRange(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if event.isAllDay { return "全天" }
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }
}

private struct MeetingIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        Circle()
            .fill(platform.iconColor.opacity(0.2))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: platform.iconName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(platform.iconColor)
            )
            .padding(.trailing, 6)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Manual test**

1. Launch NemoNotch
2. Open the notch, navigate to Calendar tab
3. Find an event with a Google Meet link (e.g., "Sage 平台沟通会")
4. Verify: hovering shows a blue video icon on the right side of the row
5. Verify: hovering highlights the row background
6. Click the event → browser opens the Google Meet link
7. Verify: events without URLs do not respond to hover or clicks

**Step 4: Commit**

```bash
git add NemoNotch/Tabs/CalendarTab.swift
git commit -m "feat(calendar): add clickable meeting events with hover indicator"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `Models/CalendarEvent.swift` | Add `url`/`location`/`notes` fields, `meetingURL` computed property, `MeetingPlatform` enum |
| `Services/CalendarService.swift` | Pass `ek.url`, `ek.location`, `ek.notes` to CalendarEvent init |
| `Tabs/CalendarTab.swift` | Replace static eventRow with hover-aware EventRowContent + MeetingIcon |

## Visual Behavior

```
Normal event (no URL):          Event with meeting URL:
┌──────────────────────┐        ┌──────────────────────────┐
│ ● 五一劳动节          │        │ ● Sage 平台沟通会  [🔵]  │  ← hover shows icon
│   全天                │        │   10:30 - 11:30          │  ← click opens link
└──────────────────────┘        └──────────────────────────┘
```
