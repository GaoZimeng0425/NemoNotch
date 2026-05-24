import AppKit

final class QuickStartWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 206),
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

    /// nil → create-new mode; non-nil → edit-existing mode
    let editingTask: TodoTask?
    let onConfirm: (FormResult) -> Void
    let onDelete: (() -> Void)?
    let onDismiss: () -> Void

    @State private var title: String = ""
    @State private var priority: TodoTask.Priority = .medium
    @State private var durationSelection: TimeInterval? = nil
    @State private var customDurationMinutes: Int = 25
    @State private var showCustomDuration: Bool = false
    @State private var mode: Mode = .continuous
    @State private var notes: String = ""
    @State private var showNotesField: Bool = false
    @State private var didHydrate: Bool = false
    @State private var pendingDeleteConfirm: Bool = false

    @FocusState private var titleFocused: Bool

    enum Mode: String, CaseIterable {
        case single, continuous
    }

    struct FormResult {
        let title: String
        let priority: TodoTask.Priority
        let duration: TimeInterval?
        let mode: Mode
        let notes: String
    }

    private var isEditMode: Bool {
        editingTask != nil
    }

    private let presetMinutes: [Int] = [15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(NotchTheme.stroke)
            bodyContent
            Divider().background(NotchTheme.stroke)
            footerBar
        }
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(NotchConstants.openedShadowOpacity), radius: NotchConstants.openedShadowRadius)
        .onAppear {
            hydrateIfNeeded()
            titleFocused = true
        }
        .onExitCommand { onDismiss() }
        .confirmationDialog(
            "pomodoro.todo.deleteConfirm",
            isPresented: $pendingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("pomodoro.todo.delete", role: .destructive) {
                onDelete?()
            }
            Button("button.cancel", role: .cancel) {}
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            headerIcon

            Text(isEditMode ? "pomodoro.edit.title" : "pomodoro.action.newPomodoro")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("button.cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerIcon: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isEditMode
                        ? [NotchTheme.surfaceWarm, NotchTheme.surface]
                        : [NotchTheme.accent, NotchTheme.accentHot],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: isEditMode ? "pencil" : "timer")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isEditMode ? NotchTheme.accentText : Color.black.opacity(0.86))
            }
            .shadow(color: NotchTheme.accent.opacity(isEditMode ? 0.18 : 0.30), radius: 10, y: 5)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isEditMode, timerService.state.isActive {
                overrideWarning
            }

            TextField(titlePlaceholder, text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(NotchTheme.textPrimary)
                .focused($titleFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )

            HStack(spacing: 8) {
                priorityPicker
                if !isEditMode {
                    durationPicker
                    if showCustomDuration {
                        customDurationStepper
                    }
                    modeToggle
                }
                Spacer()
                if !showNotesField {
                    Button {
                        showNotesField = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                            Text("pomodoro.quick.addNotes")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(NotchTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NotchTheme.surfaceSubtle, in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).stroke(NotchTheme.stroke, lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if showNotesField {
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(NotchTheme.stroke, lineWidth: 0.6)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if isEditMode {
                Button {
                    pendingDeleteConfirm = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .bold))
                        Text("pomodoro.todo.delete")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.93, green: 0.36, blue: 0.36))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Color(red: 0.93, green: 0.36, blue: 0.36).opacity(0.14),
                        in: Capsule(style: .continuous)
                    )
                    .overlay(Capsule(style: .continuous).stroke(
                        Color(red: 0.93, green: 0.36, blue: 0.36).opacity(0.30),
                        lineWidth: 0.6
                    ))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button("button.cancel") { onDismiss() }
                .buttonStyle(NotchPillButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button {
                submit()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isEditMode ? "checkmark" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(isEditMode ? "button.save" : "pomodoro.action.start")
                }
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hydrateIfNeeded() {
        guard !didHydrate, let task = editingTask else { return }
        title = task.title
        priority = task.priority
        notes = task.notes
        showNotesField = !task.notes.isEmpty
        didHydrate = true
    }

    private var overrideWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NotchTheme.accentText)
                .font(.system(size: 11))
            Text("pomodoro.quick.overrideWarning")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchTheme.accentStroke, lineWidth: 0.6)
        )
    }

    private var customDurationStepper: some View {
        HStack(spacing: 4) {
            Stepper(value: $customDurationMinutes, in: 1 ... 180) {
                Text(durationText(customDurationMinutes))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 58, alignment: .leading)
            }
            .onChange(of: customDurationMinutes) { _, newValue in
                durationSelection = TimeInterval(newValue * 60)
            }
        }
        .padding(.horizontal, 6)
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
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(NotchTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surfaceSubtle, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(NotchTheme.stroke, lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var durationPicker: some View {
        Menu {
            ForEach(presetMinutes, id: \.self) { m in
                Button(durationText(m)) {
                    durationSelection = TimeInterval(m * 60)
                    showCustomDuration = false
                }
            }
            Divider()
            Button("pomodoro.quick.duration.default") {
                durationSelection = nil
                showCustomDuration = false
            }
            Button("pomodoro.quick.customDuration") {
                showCustomDuration = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(durationLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(NotchTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surfaceSubtle, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(NotchTheme.stroke, lineWidth: 0.6))
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(mode == m ? NotchTheme.accentText : NotchTheme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            mode == m ? NotchTheme.accent.opacity(0.16) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(NotchTheme.surfaceSubtle, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(NotchTheme.stroke, lineWidth: 0.6))
    }

    private var titlePlaceholder: LocalizedStringKey {
        isEditMode ? "pomodoro.edit.titleField" : "pomodoro.quick.placeholder"
    }

    private var durationLabel: String {
        if let durationSelection {
            return durationText(Int(durationSelection / 60))
        }
        return String(localized: "pomodoro.quick.duration.default")
    }

    private func durationText(_ minutes: Int) -> String {
        String(format: String(localized: "settings.pomodoro.minutes"), minutes)
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
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEditMode {
            onConfirm(FormResult(
                title: trimmedTitle,
                priority: priority,
                duration: nil,
                mode: .continuous,
                notes: notes
            ))
            return
        }
        onConfirm(FormResult(
            title: trimmedTitle,
            priority: priority,
            duration: durationSelection,
            mode: mode,
            notes: notes
        ))
    }
}
