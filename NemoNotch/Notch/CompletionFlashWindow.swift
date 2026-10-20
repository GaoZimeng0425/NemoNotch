import SwiftUI

/// Borderless, transparent, click-through window covering one full screen.
/// Hosts the edge-glow overlay. Sits at the notch level and joins all Spaces
/// so the glow shows over fullscreen apps too.
final class CompletionFlashWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 8
        ignoresMouseEvents = true
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // close() 绝不能走默认的释放语义(isReleasedWhenClosed=true):旧窗在
        // Swift 并发 job 的 autorelease pool 里被释放后,pool 排干时对同一对象
        // 再 release → 过度释放 SIGSEGV(2026-10-14 两次实锤,栈 =
        // AutoreleasePoolPage::releaseUntil ← runJobInEstablishedExecutorContext)。
        // false 之后 close() 仅隐藏,窗口由字典引用计数自然析构(且必须先 orderOut)。
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Owns one `CompletionFlashWindow` per connected screen and keeps them in
/// sync with display changes. All windows share the same `CompletionFlashService`,
/// so a single completion flashes every screen at once.
@MainActor
final class CompletionFlashWindowController {
    private var windows: [UInt32: CompletionFlashWindow] = [:]
    /// L1:屏幕参数变化的重建立务是否已排队(同一次重配常连发多条通知,合并成一次)。
    private var rebuildPending = false
    /// 上次已应用的 overlay 可见性(去重 double-apply,见 applyOverlayVisibility)。
    private var overlayShown = false
    private let service: CompletionFlashService
    private nonisolated(unsafe) var observer: Any?

    init(service: CompletionFlashService) {
        self.service = service
        LogService.info("CompletionFlashWindowController init", category: "CompletionFlash")
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // L1:窗口销毁/重建显式推迟到下一个 runloop turn。queue: .main 的
            // 交付通常已不在派发栈内,但这个契约不该依赖 NotificationCenter 的
            // 内部实现 —— AppKit 屏幕重配派发栈内的同步重建是过度释放 SIGSEGV
            // 崩溃族的根因(见 NotchCoordinator.screenParametersChanged)。
            MainActor.assumeIsolated {
                self?.scheduleRebuild()
            }
        }
        observeOverlayVisibility()
    }

    /// L1:见 `NotchCoordinator.screenParametersChanged` 的崩溃族说明 ——
    /// 屏幕重配的窗口重建推迟一个 runloop turn,pending 标志合并连发的多条通知。
    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rebuildPending = false
            LogService.info("screen parameters changed — rebuilding flash windows", category: "CompletionFlash")
            rebuild()
        }
    }

    /// Keep the windows on screen only while there is something to show.
    ///
    /// These are one full-screen window per display (5.2MP across two displays
    /// here) hosting `.blendMode(.screen)` content. AppKit asks every *visible*
    /// window whether it needs to re-layout on each display cycle — the pass is
    /// driven by the window being on screen, not by whether its content changed
    /// or is even opaque. They used to be `orderFrontRegardless()`'d at creation
    /// and never ordered out, so that cost was permanent.
    ///
    /// The window therefore appears one runloop turn after the flash starts
    /// (this observation lands via a `Task`). Harmless in practice: the glow
    /// eases in from zero over `completionFlashRise`, so the frame that gets
    /// missed is the fully-transparent one.
    private func observeOverlayVisibility() {
        withObservationTracking {
            _ = service.overlayVisible
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                observeOverlayVisibility() // re-arm before applying so no change is missed
                applyOverlayVisibility()
            }
        }
    }

    private func applyOverlayVisibility() {
        let visible = service.overlayVisible
        // 去重:每个 onChange 边沿各自排队一个 Task,Task 执行时读的是当前值;
        // 同一 runloop turn 内两个 false→true 翻转会 double-apply(重建两轮)。
        guard visible != overlayShown else { return }
        overlayShown = visible
        guard visible else {
            for window in windows.values {
                window.orderOut(nil)
            }
            return
        }
        // 闪光开始时(overlay 从消隐转可见)**重建**窗口而非复用长期 orderOut 的旧窗。
        //
        // 具文窗口 bug(2026-10-14 定性,外接屏 DELL U2720QM + macOS 27 复现):
        // 创建后一直 orderOut、等第一次闪光才首次 orderFrontRegardless 的窗口,
        // 在**非主屏**上可能永远拿不到渲染表面 —— AppKit isVisible=true、CGWindowList
        // onscreen=true、frame 正确,但 WindowServer 里没有图像(screencapture -l 报
        // "could not create image",整块屏像素里零光晕);主屏窗口同样路径不受影响;
        // --uitest --flash(创建后立即入屏)则两块屏都正常渲染。
        // 该模式由 86c87dd(闪光时才入屏的省电优化)引入。闪光时新建窗口 + 立即
        // 入屏,复刻的正是实测能渲染的创建即入屏路径;闲置时窗口照旧 orderOut,
        // 86c87dd 要省的常驻布局开销不变。完成事件低频,每闪光新建两扇窗的代价可忽略。
        // cooldown 内合并进存活 toast 的闪光不经过这里(overlayVisible 未翻转),
        // 那些窗口常驻在屏、有表面,无需重建。
        //
        // 换出旧窗的纪律(2026-10-14 二次修复,两次 SIGSEGV 实锤):**不用 close()**,
        // 窗口操作也**不留在观察 Task(Swift 并发 job)里** —— close() 的释放语义
        // (isReleasedWhenClosed)会让旧窗在并发 job 的 autorelease pool 中被释放,
        // pool 排干时再次 release 同一对象 → 过度释放崩溃(栈 = releaseUntil ←
        // runJobInEstablishedExecutorContext)。旧窗此刻必已 orderOut(上一场闪光
        // 结束时收起),先建新窗、再 orderOut 旧窗、字典换引用后由引用计数自然析构;
        // 整段挪进普通 main-queue block,避开并发 job 的 autorelease 池。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for screen in NSScreen.screens {
                let id = screen.displayID
                let fresh = makeWindow(for: screen)
                windows[id]?.orderOut(nil)
                windows[id] = fresh
                LogService.debug("CompletionFlash window recreated for display \(id)", category: "CompletionFlash")
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        LogService.info("CompletionFlashWindowController deinit", category: "CompletionFlash")
    }

    private func rebuild() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))
        for (id, window) in windows where !currentIDs.contains(id) {
            window.orderOut(nil)
            window.close()
            windows.removeValue(forKey: id)
            LogService.debug("CompletionFlash window removed for display \(id)", category: "CompletionFlash")
        }
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
            } else {
                windows[id] = makeWindow(for: screen)
                LogService.debug("CompletionFlash window added for display \(id)", category: "CompletionFlash")
            }
        }
    }

    private func makeWindow(for screen: NSScreen) -> CompletionFlashWindow {
        let window = CompletionFlashWindow(rect: screen.frame)
        let host = NSHostingView(rootView: CompletionFlashView(service: service))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        window.contentView = host
        // Windows rebuilt mid-flash (display change) must match the current
        // state rather than always coming up on screen.
        if service.overlayVisible {
            window.orderFrontRegardless()
        }
        return window
    }
}
