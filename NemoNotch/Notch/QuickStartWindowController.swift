import AppKit
import SwiftUI

@MainActor
final class QuickStartWindowController {
    private var window: QuickStartWindow?
    private var clickOutsideMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var editingTaskID: UUID?
    /// When the panel was last shown. Clicks within `dismissGrace` of this are ignored:
    /// activating the app from background can replay the opening click into the global
    /// click-outside monitor (and re-fire the toggle), instantly self-dismissing the panel.
    private var presentedAt: Date = .distantPast
    private let dismissGrace: TimeInterval = 0.25

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
            // Ignore the duplicate invocation that can arrive when the trigger button is
            // clicked from a background window (app activation replays the click).
            if Date().timeIntervalSince(presentedAt) < dismissGrace { return }
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
        let host = makeHost(editingTask: editingTask)
        w.contentViewController = host
        w.setContentSize(host.view.fittingSize)
        captureFrontmostApp()
        center(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        presentedAt = Date()
        installClickOutsideMonitor()
        LogService.debug(
            "QuickStartWindow present (\(editingTask == nil ? "create" : "edit"))",
            category: "QuickStart"
        )
    }

    private func makeHost(editingTask: TodoTask?) -> NSHostingController<some View> {
        let controller = NSHostingController(
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
        // Keep the hosting view transparent so the rounded-corner area outside the
        // SwiftUI card stays clear — otherwise AppKit paints (and shadows) a black square.
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
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

    private func installClickOutsideMonitor() {
        uninstallClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let global = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let window = self.window, window.isVisible else { return }
                // Skip the click burst right after present (activation can replay it here).
                if Date().timeIntervalSince(self.presentedAt) < self.dismissGrace { return }
                if !window.frame.contains(global) {
                    self.dismiss()
                }
            }
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
