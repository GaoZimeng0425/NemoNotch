import AppKit

enum TerminalDetector {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
    ]

    static var isTerminalFrontmost: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundleID)
    }
}
