import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

// `kIOPMMessageClamshellStateChange` 没有被导出到 Swift(它是 C 宏
// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` 展开的结果),按
// `IOReturn.h` 里的位布局自己算。
private func errSystem(_ value: UInt32) -> UInt32 { (value & 0x3F) << 26 }
private func errSub(_ value: UInt32) -> UInt32 { (value & 0xFFF) << 14 }
private func iokitFamilyMessage(subsystem: UInt32, message: UInt32) -> UInt32 {
    errSystem(0x38) | subsystem | message
}

/// == `kIOPMMessageClamshellStateChange`
private let clamshellStateChangeMessage = natural_t(
    iokitFamilyMessage(subsystem: errSub(13), message: 0x100)
)

/// `messageArgument` 的 bit 0 表示盖子是否合上。
private let clamshellClosedBit: UInt = 1

/// 监听合盖事件,并在需要时主动熄屏。
///
/// **为什么需要**:`disablesleep=1` 之后整条睡眠路径被禁,合盖屏幕不会灭,
/// 会持续耗电发热。大多数同类项目漏掉了这一步。
///
/// 熄屏走 `pmset displaysleepnow`,**不需要 root** —— 所以策略留在无特权侧,
/// 提权面只有 `disablesleep` 那一个开关。
@MainActor
final class LidMonitor {
    private var rootDomain: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL

    /// 只有防休眠开着时才熄屏 —— 关着的时候合盖本来就会正常睡眠。
    private var isEnabled = false

    /// 合盖时是否自动熄屏。接外接显示器的 clamshell 工作模式下用户可能不想熄。
    var autoDisplayOff = true

    /// `isolated deinit` —— IOKit 句柄是 @MainActor 隔离的非 Sendable 值,
    /// 普通 nonisolated deinit 碰不到它们。
    isolated deinit {
        stop()
    }

    // MARK: - 生命周期

    func start() throws {
        guard rootDomain == IO_OBJECT_NULL else { return }

        rootDomain = Self.findRootDomain()
        guard rootDomain != IO_OBJECT_NULL else {
            LogService.error("LidMonitor.start: IOPMrootDomain not found", category: "LidMonitor")
            throw MonitorError.rootDomainUnavailable
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(rootDomain)
            rootDomain = IO_OBJECT_NULL
            LogService.error("LidMonitor.start: notification port unavailable", category: "LidMonitor")
            throw MonitorError.notificationPortUnavailable
        }
        notificationPort = port

        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            stop()
            LogService.error("LidMonitor.start: run loop source unavailable", category: "LidMonitor")
            throw MonitorError.runLoopSourceUnavailable
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // 回调来自 main runloop source,所以已经在主线程上。
                MainActor.assumeIsolated {
                    monitor.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
                }
            },
            refcon, &notifier
        )

        guard result == KERN_SUCCESS else {
            stop()
            LogService.error(
                "LidMonitor.start: IOServiceAddInterestNotification failed 0x\(String(result, radix: 16))",
                category: "LidMonitor"
            )
            throw MonitorError.interestNotificationFailed(result)
        }

        // 把订阅参数一并写进日志:万一以后合盖没反应,这一行就能区分是"订阅
        // 压根没建起来"还是"建起来了但消息没到/被条件挡掉"。clamshellMessage
        // 是手算的常量(见文件顶部),记下来便于和 IOKit 头文件核对。
        LogService.info(
            """
            LidMonitor started (clamshellMessage=0x\(String(clamshellStateChangeMessage, radix: 16)), \
            lidClosed=\(isLidClosed().map(String.init) ?? "unknown"), \
            externalDisplay=\(Self.hasExternalDisplay()))
            """,
            category: "LidMonitor"
        )
        // 记一条启动行:日后若发现某段时间完全没有合盖记录,这行能区分是
        // "确实没合过盖" 还是 "App 那段时间根本没在跑 / 订阅没建起来"。
        KeepAwakeEventLog.record(
            "监听启动 [clamshellMessage=0x\(String(clamshellStateChangeMessage, radix: 16)), "
                + "lidClosed=\(isLidClosed().map(String.init) ?? "unknown"), "
                + "externalDisplay=\(Self.hasExternalDisplay())]"
        )
    }

    func stop() {
        if notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
            notifier = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootDomain != IO_OBJECT_NULL {
            IOObjectRelease(rootDomain)
            rootDomain = IO_OBJECT_NULL
        }
        LogService.info("LidMonitor stopped", category: "LidMonitor")
    }

    // MARK: - 状态

    func setEnabled(_ enabled: Bool) {
        // 只在**变化**时记录(refresh 每次都会调用它)。低频且是合盖日志的关键
        // 上下文,所以用 .info 而非 .debug —— Release 构建只写 .info 及以上。
        guard isEnabled != enabled else { return }
        LogService.info("keep-awake \(isEnabled) → \(enabled)", category: "LidMonitor")
        isEnabled = enabled
    }

    /// 开启防休眠的瞬间,盖子可能已经是关着的(比如接着外接屏、用着外接键鼠),
    /// 补一次熄屏。
    func turnDisplayOffIfNeeded() {
        let lidClosed = isLidClosed()
        guard lidClosed == true else { return }

        let external = Self.hasExternalDisplay()
        let context = "keepAwake=\(isEnabled), autoDisplayOff=\(autoDisplayOff), externalDisplay=\(external)"

        if let reason = skipReason(isEnabled: isEnabled, autoDisplayOff: autoDisplayOff, hasExternal: external) {
            LogService.info("lid already closed on enable (\(context)) → no action: \(reason)", category: "LidMonitor")
            return
        }

        LogService.info("lid already closed on enable (\(context)) → turning display off", category: "LidMonitor")
        PMSet.displaySleepNow()
    }

    /// 读 `AppleClamshellState`。读不到(台式机、属性缺席)时返回 `nil`。
    func isLidClosed() -> Bool? {
        guard rootDomain != IO_OBJECT_NULL else { return nil }
        guard let property = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        guard CFGetTypeID(property) == CFBooleanGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return CFBooleanGetValue((property as! CFBoolean))
    }

    // MARK: - 内部

    private func handlePowerMessage(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        // kIOGeneralInterest 会送来各种电源消息(即将睡眠、唤醒、can-sleep 询问
        // 等),这里只关心 clamshell,其余静默丢弃 —— 否则日志会被刷满。
        guard messageType == clamshellStateChangeMessage else { return }

        let isClosed = (UInt(bitPattern: messageArgument) & clamshellClosedBit) != 0

        guard isClosed else {
            LogService.info("lid opened", category: "LidMonitor")
            KeepAwakeEventLog.record("盖子打开")
            return
        }

        // 全部记到 .info:合盖是低频事件(不是轮询循环),而这条日志的意义正是
        // 让"合盖到底有没有被正确处理"可以事后从日志回溯,不必特意做实验。
        // 因此这里连**为什么没动作**也要写清楚 —— 只记成功路径的话,没熄屏时
        // 无法区分"事件根本没来"和"事件来了但被条件挡掉"。
        let external = Self.hasExternalDisplay()
        let context = "keepAwake=\(isEnabled), autoDisplayOff=\(autoDisplayOff), externalDisplay=\(external)"

        if let reason = skipReason(isEnabled: isEnabled, autoDisplayOff: autoDisplayOff, hasExternal: external) {
            LogService.info("lid closed (\(context)) → no action: \(reason)", category: "LidMonitor")
            KeepAwakeEventLog.record("盖子合上 [\(context)] → 未熄屏:\(reason)")
            return
        }

        LogService.info("lid closed (\(context)) → turning display off", category: "LidMonitor")
        KeepAwakeEventLog.record("盖子合上 [\(context)] → 熄屏")
        PMSet.displaySleepNow()
    }

    /// 不熄屏的原因;`nil` 表示应当熄屏。抽出来是为了让"跳过"在日志里带上
    /// 可读的理由,而不是一个静默的 `guard`。
    private func skipReason(isEnabled: Bool, autoDisplayOff: Bool, hasExternal: Bool) -> String? {
        if !isEnabled { return "keep-awake is off" }
        if !autoDisplayOff { return "auto display-off disabled in settings" }
        // 有外接显示器时不熄屏 —— 那正是用户想要的 clamshell 工作模式。
        if hasExternal { return "an external display is attached" }
        return nil
    }

    private static func hasExternalDisplay() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }
        return displays.prefix(Int(displayCount)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func findRootDomain() -> io_service_t {
        let matched = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")
        )
        if matched != IO_OBJECT_NULL { return matched }

        return IORegistryEntryFromPath(
            kIOMainPortDefault,
            "IOService:/IOResources/IOPowerConnection/IOPMrootDomain"
        )
    }

    enum MonitorError: LocalizedError {
        case rootDomainUnavailable
        case notificationPortUnavailable
        case runLoopSourceUnavailable
        case interestNotificationFailed(kern_return_t)

        var errorDescription: String? {
            switch self {
            case .rootDomainUnavailable: "Could not find IOPMrootDomain."
            case .notificationPortUnavailable: "Could not create an IOKit notification port."
            case .runLoopSourceUnavailable: "Could not create an IOKit run loop source."
            case let .interestNotificationFailed(code):
                "Could not subscribe to clamshell notifications: 0x\(String(code, radix: 16))."
            }
        }
    }
}
