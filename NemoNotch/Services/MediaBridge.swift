import AppKit
import Foundation
import ScriptingBridge

enum KnownPlayer: String, CaseIterable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    init?(bundleID: String?) {
        guard let bundleID, let p = KnownPlayer(rawValue: bundleID) else { return nil }
        self = p
    }

    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

/// Captures AppleEvent failures from ScriptingBridge calls (most notably
/// `errAEEventNotPermitted = -1743` — user denied Automation permission).
private final class PlayerEventDelegate: NSObject, SBApplicationDelegate, @unchecked Sendable {
    static let shared = PlayerEventDelegate()
    override private init() {}

    /// Most recent AppleEvent error code captured by this delegate, or 0 if
    /// no failure has occurred since the last reset. Used for synchronous
    /// probe/grant detection.
    private(set) var lastErrorCode: Int = 0

    func resetLastError() {
        lastErrorCode = 0
    }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        let code = (error as NSError).code
        lastErrorCode = code
        LogService.warn(
            "MediaBridge: AppleEvent failed code=\(code) error=\(error.localizedDescription)",
            category: "media"
        )
        if code == -1743 {
            MediaBridge.notifyPermissionDenied()
        }
        return nil
    }
}

/// Type-erased handle to a ScriptingBridge player. Centralizes the per-vendor
/// dispatch so the public API stays a single switch.
private enum PlayerHandle {
    case spotify(SpotifyApplication)
    case music(MusicApplication)

    static func resolve(_ player: KnownPlayer) -> PlayerHandle? {
        switch player {
        case .spotify:
            guard let app: SpotifyApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
            (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
            return .spotify(app)
        case .music:
            guard let app: MusicApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
            (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
            return .music(app)
        }
    }

    var position: Double? {
        switch self {
        case let .spotify(a): return a.playerPosition
        case let .music(a): return a.playerPosition
        }
    }

    /// Authoritative play state directly from the player app.
    var isPlaying: Bool? {
        switch self {
        case let .spotify(a): return a.playerState == .playing
        case let .music(a):
            let s = a.playerState
            return s == .playing || s == .fastForwarding || s == .rewinding
        }
    }
}

@MainActor
enum MediaBridge {
    private static let permissionRequestedKey = "NemoNotch.MediaBridge.permissionRequested"

    /// bundleIDs we have already poked for automation permission. Persisted
    /// across launches so the system dialog isn't repeatedly triggered.
    private static var permissionRequested: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: permissionRequestedKey) ?? []
        return Set(stored)
    }()

    /// Last bundleID whose automation request was denied by the user. Set by
    /// the SBApplication delegate when an AppleEvent returns errAEEventNotPermitted.
    /// MediaService observes this via `permissionDeniedCallback`.
    static var permissionDeniedCallback: ((String) -> Void)?
    private static var lastDeniedBundleID: String?

    /// Returns true if the target app is currently running. SBApplication
    /// would otherwise *launch* it on first command, which is rarely desired.
    static func isRunning(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Synchronously check whether Automation access is currently granted by
    /// performing a benign read and inspecting the delegate's error code.
    /// Returns true if access works, false if denied.
    static func hasAutomationAccess(bundleID: String?) -> Bool {
        guard let bundleID, let player = KnownPlayer(bundleID: bundleID) else { return false }
        guard isRunning(bundleID: bundleID) else { return false }
        PlayerEventDelegate.shared.resetLastError()
        _ = PlayerHandle.resolve(player)?.position
        return PlayerEventDelegate.shared.lastErrorCode != -1743
    }

    /// Trigger the macOS Automation permission dialog by performing a benign
    /// ScriptingBridge call on the target app. Fires at most once per
    /// bundleID across launches.
    static func requestPermissionIfNeeded(bundleID: String?) {
        guard let bundleID, let player = KnownPlayer(bundleID: bundleID) else { return }
        guard !permissionRequested.contains(bundleID) else { return }
        // Don't spawn the player just to ask for permission — the user is
        // already using it (that's why metadata is in Now Playing), so this
        // should always be true in practice, but guard anyway.
        guard isRunning(bundleID: bundleID) else { return }
        permissionRequested.insert(bundleID)
        UserDefaults.standard.set(Array(permissionRequested), forKey: permissionRequestedKey)
        _ = PlayerHandle.resolve(player)?.position
    }

    /// Query the player's actual play state via ScriptingBridge.
    /// Returns nil for unknown players or if the app isn't running.
    ///
    /// This is now the only repeated ScriptingBridge call (control moved to the
    /// `mediaremote-adapter` perl bridge), so it records `lastDeniedBundleID` for
    /// the async permission-denied callback in case this AppleEvent is refused.
    static func isPlaying(bundleID: String?) -> Bool? {
        guard let bundleID, isRunning(bundleID: bundleID) else { return nil }
        lastDeniedBundleID = bundleID
        return handle(for: bundleID)?.isPlaying
    }

    /// Called by the SBApplication delegate (any thread) when AppleEvents fail
    /// with errAEEventNotPermitted.
    nonisolated static func notifyPermissionDenied() {
        Task { @MainActor in
            guard let bundleID = lastDeniedBundleID else { return }
            permissionDeniedCallback?(bundleID)
        }
    }

    /// Opens System Settings → Privacy → Automation so the user can grant access.
    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    private static func handle(for bundleID: String?) -> PlayerHandle? {
        guard let player = KnownPlayer(bundleID: bundleID) else { return nil }
        return PlayerHandle.resolve(player)
    }
}
