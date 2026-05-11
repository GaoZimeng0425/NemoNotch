import Foundation

enum MediaBridge {
    private static let seekableApps: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
    ]

    static func supportsSeeking(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return seekableApps.contains(bundleID)
    }

    static func playerPosition(bundleID: String?) -> Double? {
        guard let bundleID else { return nil }
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return nil
        }
        let script = "tell application \"\(appName)\" to return playerPosition"
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(nil) else { return nil }
        return result.doubleValue
    }

    static func setPlayerPosition(bundleID: String?, position: Double) {
        guard let bundleID else { return }
        let appName: String
        switch bundleID {
        case "com.apple.Music": appName = "Music"
        case "com.spotify.client": appName = "Spotify"
        default: return
        }
        let script = "tell application \"\(appName)\" to set playerPosition to \(position)"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
