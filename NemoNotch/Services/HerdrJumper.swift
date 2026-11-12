import AppKit
import Foundation

/// Click target for external cards carrying `herdrTerminal`: focuses that agent
/// inside Herdr. Herdr has no URL scheme (no `CFBundleURLTypes`), so the only
/// external entry is its CLI — the app binary itself in CLI mode
/// (`Herdr do agent.focus --terminal <addr>`; `~/.local/bin/herdr-app` is a
/// symlink to it). The address was validated at the API edge
/// (`ExternalToastPayload`); the executable and verb are fixed here, and the
/// call never goes through a shell.
enum HerdrJumper {
    static let bundleId = "dev.herdr.app"
    private static let timeout: TimeInterval = 3

    static func arguments(terminal: String) -> [String] {
        ["do", "agent.focus", "--terminal", terminal]
    }

    static func executableURL(appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/MacOS/Herdr")
    }

    enum Outcome: Equatable {
        case focused
        case fallbackOpenApp
    }

    /// 0 → the agent is focused; anything else (non-zero, or nil: not
    /// installed / failed to launch / timed out) → just open Herdr.
    static func plan(exitStatus: Int32?) -> Outcome {
        exitStatus == 0 ? .focused : .fallbackOpenApp
    }

    /// Runs the CLI off the main thread, then brings Herdr forward either way
    /// (Launch Services open also launches it when it has quit).
    @MainActor
    static func focus(terminal: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            LogService.warn("Herdr not installed; cannot focus \(terminal)", category: "HerdrJumper")
            return
        }
        let executable = executableURL(appURL: appURL)
        let args = arguments(terminal: terminal)
        Task.detached {
            let status = run(executable: executable, arguments: args)
            await MainActor.run {
                switch plan(exitStatus: status) {
                case .focused:
                    LogService.info("Focused Herdr agent \(terminal)", category: "HerdrJumper")
                case .fallbackOpenApp:
                    LogService.warn(
                        "Herdr agent.focus \(terminal) failed (exit \(status.map(String.init) ?? "nil")); opening Herdr",
                        category: "HerdrJumper"
                    )
                }
                AppActivator.openApp(bundleId: bundleId)
            }
        }
    }

    /// Blocking; bounded by `timeout`. nil when it could not start or timed out.
    private static func run(executable: URL, arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}
