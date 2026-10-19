import AppKit

/// Activates the GUI app (terminal/IDE) that launched a given AI session.
///
/// The hook script reports the CLI's own pid (`cli_pid` = bash's `$PPID`); at
/// event time `recordHost(cliPID:on:)` walks the process tree up to the first
/// GUI app and caches pid + bundle id on the session. Resolving at event time
/// (rather than click time) keeps the host valid after the CLI itself exits.
///
/// Activation prefers the cached **PID** — `NSRunningApplication(
/// processIdentifier:)` activates that specific process instance, so two
/// windows of the same app (e.g. two iTerm windows each running a Claude
/// session) can be told apart. PIDs are reused after a process exits, so the
/// cached `launchingAppBundleId` is validated against the looked-up app before
/// activating; on mismatch (or when the PID is gone) we fall back to bundle-id
/// activation. No Accessibility permission needed for any of this.
enum AppActivator {
    /// Activate the launching app of a session.
    /// - Parameters:
    ///   - pid: Host app PID resolved at event time (may be stale if the app quit).
    ///   - expectedBundleId: bundle id resolved alongside `pid` and cached on
    ///     the session; used to detect PID reuse. May be nil if the app had no
    ///     readable bundle id.
    ///   - tabLink: tab-reveal URL captured from the CLI's environment
    ///     (`TabLink`); when present and openable it wins — the terminal
    ///     reveals its own tab, which is strictly more precise than pid
    ///     activation (app-level at best otherwise).
    @MainActor
    static func activate(pid: Int32?, expectedBundleId: String?, tabLink: String? = nil) {
        // 0. Tab-level jump when the terminal published a link.
        if let tabLink, let url = URL(string: tabLink) {
            LogService.info("Jumping via tab link: \(tabLink)", category: "AppActivator")
            if NSWorkspace.shared.open(url) {
                return
            }
            LogService.warn("Tab link failed to open; falling back to app activation", category: "AppActivator")
        }
        // 1. Prefer PID activation (precise to the window/process).
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            if let expected = expectedBundleId,
               let actual = app.bundleIdentifier,
               actual != expected {
                // PID now refers to a different app (reuse) — fall back to bundle id.
                LogService.info(
                    "Host pid \(pid) reused by \(actual); activating bundle \(expected) instead",
                    category: "AppActivator"
                )
                activateBundle(expected)
            } else {
                LogService.info("Activating session host pid \(pid)", category: "AppActivator")
                app.activate()
            }
            return
        }
        // 2. PID no longer resolves (app exited) — fall back to bundle id, which
        //    activates any surviving instance of the same app.
        if let expected = expectedBundleId {
            LogService.info(
                "Host pid \(pid.map(String.init) ?? "nil") is gone; activating bundle \(expected)",
                category: "AppActivator"
            )
            activateBundle(expected)
        } else {
            LogService.warn(
                "No host app to activate (pid \(pid.map(String.init) ?? "nil"), no bundle id)",
                category: "AppActivator"
            )
        }
    }

    /// Resolve and cache the hosting GUI app for a session, from the CLI pid
    /// the hook reported. Called per routed hook event on the main actor; the
    /// walk is a handful of sysctls (no subprocesses) so per-event cost is
    /// negligible, and a no-op once the host stops changing.
    ///
    /// A walk that finds no GUI app (tmux/ssh chains top out at launchd, or
    /// the CLI already exited) keeps any previously resolved host rather than
    /// clearing it on a transient miss.
    @MainActor
    static func recordHost(cliPID: Int32, on session: inout AISessionState) {
        // Tab link first: it lives in the CLI's own inherited environment and
        // never changes for the process's lifetime, so it is read only until
        // captured. Independent of the GUI-host walk below (a CLI whose tree
        // tops out at launchd can still carry one).
        if session.tabLinkURL == nil, let url = TabLink.resolve(ProcessEnvironment.of(cliPID)) {
            session.tabLinkURL = url.absoluteString
            LogService.info(
                "Tab link captured for \(session.id.prefix(8)): \(url.absoluteString)",
                category: "AppActivator"
            )
        }
        guard let host = hostAppPID(of: cliPID), session.launchingAppPID != host else { return }
        session.launchingAppPID = host
        session.launchingAppBundleId = bundleId(forPid: host)
        LogService.info(
            "Session host app resolved: pid \(host), bundle \(session.launchingAppBundleId ?? "?")",
            category: "AppActivator"
        )
    }

    /// Walk the process tree upward from `pid` and return the first entry
    /// (including `pid` itself) that belongs to a GUI app — i.e. the terminal
    /// or IDE hosting the CLI. `NSRunningApplication` is documented
    /// thread-safe; callers are on the main actor anyway.
    static func hostAppPID(of pid: pid_t) -> Int32? {
        var current = pid
        // Bound guards against pathological depth; real chains are ≤ ~6 hops
        // (hook bash → CLI → shell → login → terminal app).
        for _ in 0 ..< 16 {
            if NSRunningApplication(processIdentifier: current) != nil {
                return current
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// Resolve the bundle id of a running process by PID.
    static func bundleId(forPid pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Parent PID lookup via `sysctl(KERN_PROC_PID)` — public BSD interface,
    /// no permission and no subprocess. Returns nil for exited/recycled pids.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        // The buffer's length IN: with 0 sysctl returns -1/ENOMEM and writes
        // nothing — the walk never left the CLI pid (terminal-hosted sessions
        // got no host, so no Go-to-session).
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid
        else { return nil }
        // ppid lives in kp_eproc (extern_proc itself has no p_ppid member).
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    private static func activateBundle(_ bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?
            .activate()
    }
}
