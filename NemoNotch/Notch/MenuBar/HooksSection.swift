import SwiftUI

/// Menu-bar quick actions per CLI: offer "enable monitoring" when the toggle
/// is off, or a heal install when monitoring is on but the hook is missing.
/// Bare `installHooks()` is gone — installing while disabled would recreate
/// the "uninstalled but resurrects" contradiction.
struct HooksSection: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AICLIMonitorService.self) private var aiService

    var body: some View {
        ForEach(missing, id: \.0) { name, source in
            Button("menu.enable_monitoring \(name)") {
                appSettings[source] = true
                aiService.setMonitoring(enabled: true, for: source)
            }
        }
        if !missing.isEmpty {
            Divider()
        }
    }

    private var missing: [(String, AISource)] {
        var result: [(String, AISource)] = []
        let all: [(name: String, source: AISource)] = [
            ("Claude Code", .claude), ("Gemini CLI", .gemini),
            ("opencode", .opencode), ("zcode", .zcode),
        ]
        for (name, source) in all {
            if !appSettings[source] || !aiService.provider(for: source).isHookInstalled {
                result.append((name, source))
            }
        }
        return result
    }
}
