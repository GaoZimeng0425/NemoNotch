import AppKit
import SwiftUI

@MainActor
final class QuickStartWindowController {
    private var window: QuickStartWindow?
    private var clickOutsideMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var editingTaskID: UUID?

    private let timerService: PomodoroTimerService
    private let taskStore: TaskStore
    private let appSettings: AppSettings
    private let notificationMonitor: NotificationPermissionMonitor
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier

    init(
        timerService: PomodoroTimerService,
        taskStore: TaskStore,
        appSettings: AppSettings,
        notificationMonitor: NotificationPermissionMonitor
    ) {
        self.timerService = timerService
        self.taskStore = taskStore
        self.appSettings = appSettings
        self.notificationMonitor = notificationMonitor
    }

    func toggle() {
        if let window, window.isVisible {
            dismiss()
        } else {
            present(editingTask: nil)
        }
    }

    func presentEdit(taskID: UUID) {
        guard let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }
        present(editingTask: task)
    }

    func dismiss() {
        uninstallClickOutsideMonitor()
        window?.orderOut(nil)
        editingTaskID = nil
        restorePreviousApp()
        LogService.debug("QuickStartWindow dismiss", category: "QuickStart")
    }

    private func present(editingTask: TodoTask?) {
        editingTaskID = editingTask?.id
        let w = window ?? QuickStartWindow()
        window = w
        w.contentViewController = makeHost(editingTask: editingTask)
        captureFrontmostApp()
        center(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickOutsideMonitor(for: w)
        LogService.debug(
            "QuickStartWindow present (\(editingTask == nil ? "create" : "edit"))",
            category: "QuickStart"
        )
    }

    private func makeHost(editingTask: TodoTask?) -> NSHostingController<some View> {
        NSHostingController(
            rootView: QuickStartFormView(
                editingTask: editingTask,
                onConfirm: { [weak self] result in self?.handleConfirm(result) },
                onDelete: { [weak self] in self?.handleDelete() },
                onDismiss: { [weak self] in self?.dismiss() }
            )
            .environment(timerService)
            .environment(taskStore)
            .environment(appSettings)
            .environment(notificationMonitor)
        )
    }

    private func center(_ w: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.frame
        let size = w.frame.size
        let frame = NSRect(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2 + 80,
            width: size.width,
            height: size.height
        )
        w.setFrame(frame, display: false)
    }

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        let currentFront = NSWorkspace.shared.frontmostApplication
        if currentFront == nil || currentFront?.bundleIdentifier == Self.ourBundleIdentifier {
            app.activate()
        }
    }

    private func installClickOutsideMonitor(for window: NSWindow) {
        uninstallClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            let global = NSEvent.mouseLocation
            if !window.frame.contains(global) {
                Task { @MainActor in self.dismiss() }
            }
            _ = event
        }
    }

    private func uninstallClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    private func handleConfirm(_ result: QuickStartFormView.FormResult) {
        if let taskID = editingTaskID {
            let trimmed = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            taskStore.update(taskID) { task in
                if !trimmed.isEmpty {
                    task.title = trimmed
                }
                task.priority = result.priority
                task.notes = result.notes
            }
            dismiss()
            return
        }
        var taskID: UUID? = nil
        if !result.title.isEmpty {
            taskID = taskStore.add(
                title: result.title,
                priority: result.priority,
                notes: result.notes,
                tags: [],
                dueDate: nil
            )
        }
        let autoFlow = (result.mode == .continuous)
        let duration = result.duration ?? appSettings.pomodoroWorkDuration
        timerService.start(taskID: taskID, duration: duration, autoFlow: autoFlow)
        dismiss()
    }

    private func handleDelete() {
        guard let taskID = editingTaskID else { return }
        taskStore.delete(taskID)
        dismiss()
    }
}

extension EnvironmentValues {
    @Entry var quickStartController: QuickStartWindowController?
}
