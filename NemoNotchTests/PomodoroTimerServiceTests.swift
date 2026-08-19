import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct PomodoroTimerServiceTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeService() -> (PomodoroTimerService, TaskStore, PomodoroHistoryStore, AppSettings) {
        let tasks = TaskStore(fileURL: tempURL("tasks.json"))
        let history = PomodoroHistoryStore(fileURL: tempURL("history.json"))
        let settings = AppSettings()
        settings.pomodoroSoundEnabled = false
        settings.pomodoroNotificationEnabled = false
        let service = PomodoroTimerService(
            taskStore: tasks,
            historyStore: history,
            appSettings: settings,
            permissionMonitor: nil
        )
        return (service, tasks, history, settings)
    }

    // MARK: - Task 7: initial state

    @Test func initialStateIsIdle() {
        let (service, _, _, _) = makeService()
        if case .idle = service.state {} else {
            Issue.record("expected idle, got \(service.state)")
        }
        #expect(service.workCounterSinceLongBreak == 0)
        #expect(service.currentPhase == .idle)
        #expect(service.remainingSeconds == 0)
        #expect(service.state.isActive == false)
    }

    // MARK: - Task 8: start / pause / resume

    @Test func startFromIdleEntersRunningWork() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        guard case let .running(ctx) = service.state else {
            Issue.record("expected running, got \(service.state)")
            return
        }
        #expect(ctx.phase == .work)
        #expect(ctx.taskID == nil)
        #expect(ctx.plannedDuration == 60)
        #expect(ctx.accumulatedElapsed == 0)
        #expect(ctx.autoFlow == true)
    }

    @Test func startWithTaskCarriesTaskID() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: false)
        guard case let .running(ctx) = service.state else {
            Issue.record("not running")
            return
        }
        #expect(ctx.taskID == id)
        #expect(ctx.autoFlow == false)
    }

    @Test func startUpdatesLastUsedDuration() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 45 * 60, autoFlow: true)
        #expect(service.lastUsedDuration == 45 * 60)
    }

    @Test func pauseFromRunningEntersPaused() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        guard case .paused = service.state else {
            Issue.record("not paused")
            return
        }
    }

    @Test func pausePreservesPartialElapsed() async throws {
        let (service, _, _, _) = makeService()
        let plannedDuration: TimeInterval = 60

        let before = Date()
        service.start(taskID: nil, duration: plannedDuration, autoFlow: true)
        try await Task.sleep(for: .milliseconds(30))
        service.pause()
        let wallElapsed = Date().timeIntervalSince(before)

        guard case let .paused(ctx) = service.state else {
            Issue.record("not paused")
            return
        }
        #expect(ctx.accumulatedElapsed > 0)
        // 上界跟随**实际经过的挂钟时间**,而不是"sleep 30ms 就约等于 30ms"的
        // 假设。并行跑整个测试套件时那句 sleep 可能真的睡上好几秒(实测 2.6s),
        // 原先写死的 `< 1.0` 于是随机误报 —— 属于测试自身的缺陷,不是被测代码
        // 的问题。`wallElapsed` 从 start 之前量到 pause 之后,所以累计时间不可
        // 能超过它。
        #expect(ctx.accumulatedElapsed <= wallElapsed)
        // 真正要守的性质:pause 只累计了"部分",远没走完计划时长。
        #expect(ctx.accumulatedElapsed < plannedDuration)
    }

    @Test func resumeFromPausedEntersRunning() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.resume()
        guard case .running = service.state else {
            Issue.record("not running")
            return
        }
    }

    @Test func pauseFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.pause()
        if case .idle = service.state {} else {
            Issue.record("idle pause changed state")
        }
    }

    @Test func resumeFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.resume()
        if case .idle = service.state {} else {
            Issue.record("idle resume changed state")
        }
    }

    // MARK: - Task 9: completeEarly / abandon / naturalEnd

    @Test func completeEarlyFromRunningWritesPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.completeEarly()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .partial)
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
    }

    @Test func completeEarlyOnWorkIncrementsTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.completeEarly()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 1)
    }

    @Test func abandonWritesAbandonedRecord() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.abandon()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .abandoned)
        #expect(history.records.first?.outcome == .abandoned)
    }

    @Test func abandonDoesNotIncrementTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.abandon()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 0)
    }

    @Test func naturalEndWritesCompleted() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .completed)
        #expect(history.records.first?.outcome == .completed)
        #expect(history.records.first?.actualDuration == 60)
    }

    @Test func naturalEndOnWorkIncrementsTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 1)
    }

    @Test func breakNaturalEndDoesNotIncrementTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.startForTesting(phase: .shortBreak, taskID: id, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 0)
    }

    @Test func completeEarlyFromPausedAlsoWorks() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.completeEarly()
        #expect(history.records.first?.outcome == .partial)
    }

    // MARK: - Task 10: autoFlow advance()

    @Test func advanceFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("idle advance changed state")
        }
    }

    @Test func advanceAfterAbandonGoesIdle() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.abandon()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("not idle after abandon→advance")
        }
    }

    @Test func advanceAfterPartialGoesIdleEvenIfAutoFlow() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.completeEarly()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("partial advance with autoFlow should still go idle")
        }
    }

    @Test func advanceAfterCompleteWithoutAutoFlowGoesIdle() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: false)
        service.simulateNaturalEnd()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("single-mode complete advance should go idle")
        }
    }

    @Test func advanceAfterWorkCompleteWithAutoFlowGoesShortBreak() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        service.advance()
        guard case let .running(ctx) = service.state else {
            Issue.record("not running")
            return
        }
        #expect(ctx.phase == .shortBreak)
        #expect(service.workCounterSinceLongBreak == 1)
    }

    @Test func longBreakTriggeredEveryNthWork() {
        let (service, _, _, settings) = makeService()
        settings.pomodoroLongBreakInterval = 4

        for i in 1 ... 4 {
            service.start(taskID: nil, duration: 60, autoFlow: true)
            service.simulateNaturalEnd()
            service.advance()
            if i < 4 {
                guard case let .running(ctx) = service.state else {
                    Issue.record("step \(i): not running")
                    return
                }
                #expect(ctx.phase == .shortBreak, "step \(i): expected shortBreak")
                service.simulateNaturalEnd()
                service.advance()
                guard case let .running(ctx2) = service.state else {
                    Issue.record("step \(i): not running after break")
                    return
                }
                #expect(ctx2.phase == .work)
            }
        }
        guard case let .running(ctx) = service.state else {
            Issue.record("not running after 4th work")
            return
        }
        #expect(ctx.phase == .longBreak)
        #expect(service.workCounterSinceLongBreak == 4)
    }

    @Test func longBreakCompleteResetsCounter() {
        let (service, _, _, settings) = makeService()
        settings.pomodoroLongBreakInterval = 2

        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        service.advance() // → shortBreak (counter=1)
        service.simulateNaturalEnd()
        service.advance() // → work
        service.simulateNaturalEnd()
        service.advance() // → longBreak (counter=2)

        guard case let .running(longCtx) = service.state else {
            Issue.record("expected longBreak running")
            return
        }
        #expect(longCtx.phase == .longBreak)

        service.simulateNaturalEnd()
        service.advance() // → work, counter reset
        #expect(service.workCounterSinceLongBreak == 0)
        guard case let .running(workCtx) = service.state else {
            Issue.record("expected work running")
            return
        }
        #expect(workCtx.phase == .work)
    }

    // MARK: - Task 11: covering start re-entry

    @Test func startWhileRunningOverwritesAsPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.start(taskID: nil, duration: 30, autoFlow: true)
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
        guard case let .running(ctx) = service.state else {
            Issue.record("not running after override")
            return
        }
        #expect(ctx.plannedDuration == 30)
    }

    @Test func startWhilePausedOverwritesAsPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.start(taskID: nil, duration: 30, autoFlow: true)
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
        guard case .running = service.state else {
            Issue.record("not running after override-from-paused")
            return
        }
    }

    // MARK: - Task 13: system sleep

    @Test func systemSleepAbandonsRunningPomodoro() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.handleSystemWillSleepForTesting()
        #expect(history.records.first?.outcome == .abandoned)
    }

    @Test func systemSleepWhenIdleNoOp() {
        let (service, _, history, _) = makeService()
        service.handleSystemWillSleepForTesting()
        #expect(history.records.isEmpty)
    }
}
