import SwiftUI

struct HooksSection: View {
    @Environment(AICLIMonitorService.self) private var aiService

    var body: some View {
        if !aiService.claudeProvider.isHookInstalled {
            Button("menu.install_claude_hooks") {
                aiService.claudeProvider.installHooks()
            }
        }
        if !aiService.geminiProvider.isHookInstalled {
            Button("menu.install_gemini_hooks") {
                aiService.geminiProvider.installHooks()
            }
        }
        if !aiService.opencodeProvider.isHookInstalled {
            Button("menu.install_opencode_hooks") {
                aiService.opencodeProvider.installHooks()
            }
        }
        if !aiService.zcodeProvider.isHookInstalled {
            Button("menu.install_zcode_hooks") {
                aiService.zcodeProvider.installHooks()
            }
        }
        if showsAnyHook {
            Divider()
        }
    }

    private var showsAnyHook: Bool {
        !aiService.claudeProvider.isHookInstalled
            || !aiService.geminiProvider.isHookInstalled
            || !aiService.opencodeProvider.isHookInstalled
            || !aiService.zcodeProvider.isHookInstalled
    }
}
