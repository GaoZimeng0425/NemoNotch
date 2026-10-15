import AppKit
import SwiftUI

/// Settings 窗口的最小 AppKit 修正层。
///
/// 窗口骨架(双栏/侧栏开关/搜索条/玻璃背景)全部交给 SwiftUI 的
/// `NavigationSplitView`(Atoll 同构)——这里**不再**手装 NSToolbar:
/// 手装的透明标题条 + 工具栏会在标题带与内容玻璃之间叠出可见接缝,
/// 而且侧栏开关/搜索都得自己造。SwiftUI 自带的标准侧栏开关按钮 +
/// 标准标题栏没有这些问题。
///
/// 唯一剩下的修正:SwiftUI `Settings` 场景造出的窗口天生没有
/// `.resizable`,用户无法拖拽缩放。内容的 frame(minWidth:minHeight:)
/// 会以 auto-layout 约束落在 hosting view 上,拖不破版式。
enum SettingsWindowChrome {
    /// SwiftUI Settings 场景窗口的 frame autosave 名(实测常量,`NSWindow Frame
    /// com_apple_SwiftUI_Settings_window` 即由它写入)。用它认窗口是确定性的:
    /// 按标题匹配在真机上会扑空(title 在 onAppear 时未必就位),而 notch 各窗口
    /// 与它天然互斥——只有 Settings 场景窗口带这个 autosave 名。
    private static let settingsAutosaveName = "com_apple_SwiftUI_Settings_window"

    /// 幂等安装。在 SettingsView.onAppear 调用;此刻窗口的 autosave 名可能尚未
    /// 就位(场景的窗口元数据晚于内容出现),找不到就短暂重试。
    @MainActor static func install(retries: Int = 8) {
        guard let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == settingsAutosaveName
        }) else {
            guard retries > 0 else {
                let dump = NSApp.windows
                    .map {
                        "\($0.frameAutosaveName.isEmpty ? "-" : $0.frameAutosaveName)|'\($0.title)'|vis=\($0.isVisible)"
                    }
                    .joined(separator: "; ")
                LogService.warn(
                    "Settings window fixup gave up: window not found. windows=[\(dump)]",
                    category: "Settings"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                install(retries: retries - 1)
            }
            return
        }
        // 幂等:已经可缩放就什么都不做。
        guard !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
        LogService.info(
            "Settings window resizable=\(window.styleMask.contains(.resizable))",
            category: "Settings"
        )
    }
}
