import AppKit

final class QuickStartWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

import SwiftUI

struct QuickStartFormView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(PomodoroTimerService.self) var timerService

    let onConfirm: (FormResult) -> Void
    let onDismiss: () -> Void

    @State private var title: String = ""
    @State private var priority: TodoTask.Priority = .medium
    @State private var durationSelection: TimeInterval? = nil
    @State private var customDurationMinutes: Int = 25
    @State private var showCustomDuration: Bool = false
    @State private var mode: Mode = .continuous
    @State private var notes: String = ""
    @State private var showNotesField: Bool = false

    @FocusState private var titleFocused: Bool

    enum Mode: String, CaseIterable {
        case single, continuous
    }

    struct FormResult {
        let title: String
        let priority: TodoTask.Priority
        let duration: TimeInterval
        let mode: Mode
        let notes: String
    }

    private let presetMinutes: [Int] = [15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("🍅")
                    .font(.system(size: 16))
                TextField("pomodoro.quick.placeholder", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit { submit() }
            }

            HStack(spacing: 8) {
                priorityPicker
                durationPicker
                modeToggle
                Spacer()
                Image(systemName: "return")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textTertiary)
            }

            if !showNotesField {
                Button {
                    showNotesField = true
                } label: {
                    Text("pomodoro.quick.addNotes")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { titleFocused = true }
        .onExitCommand { onDismiss() }
    }

    private var priorityPicker: some View {
        Menu {
            ForEach(TodoTask.Priority.allCases, id: \.self) { p in
                Button(priorityLabel(p)) { priority = p }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(priorityColor(priority)).frame(width: 6, height: 6)
                Text(priorityLabel(priority))
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surface, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var durationPicker: some View {
        Menu {
            ForEach(presetMinutes, id: \.self) { m in
                Button("\(m) min") {
                    durationSelection = TimeInterval(m * 60)
                    showCustomDuration = false
                }
            }
            Divider()
            Button("Custom…") {
                showCustomDuration = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(durationLabel)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surface, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    mode = m
                } label: {
                    Text(modeLabel(m))
                        .font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(mode == m ? NotchTheme.surfaceEmphasis : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationLabel: String {
        if let durationSelection {
            return "\(Int(durationSelection / 60)) min"
        }
        return String(localized: "pomodoro.quick.duration.placeholder")
    }

    private func priorityLabel(_ p: TodoTask.Priority) -> String {
        switch p {
        case .low: return String(localized: "pomodoro.priority.low")
        case .medium: return String(localized: "pomodoro.priority.medium")
        case .high: return String(localized: "pomodoro.priority.high")
        }
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .low: return NotchTheme.textTertiary
        case .medium: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .high: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }

    private func modeLabel(_ m: Mode) -> String {
        switch m {
        case .single: return String(localized: "pomodoro.quick.mode.single")
        case .continuous: return String(localized: "pomodoro.quick.mode.continuous")
        }
    }

    private func submit() {
        guard let duration = durationSelection else {
            return
        }
        onConfirm(FormResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            duration: duration,
            mode: mode,
            notes: notes
        ))
    }
}
