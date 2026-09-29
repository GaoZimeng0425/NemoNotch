import AppKit
import SwiftUI

/// Settings 窗口的 AppKit 工具栏桥。
///
/// macOS 26 的 SwiftUI 不提供把按钮放进窗口标题条(红绿灯所在排)的途径:
/// `.toolbar` 的各种 placement 要么落进每列自己的第二排 header(NavigationSplitView),
/// 要么生成同样的悬空横带;`ignoresSafeArea` 伸进标题条的内容又被系统材质层盖住。
/// 唯一确定性方案是真正的 NSToolbar——AppKit 工具栏项天然渲染在红绿灯同排
/// (Finder 同款)。按钮动作走 NotificationCenter,由 SettingsView 订阅翻转侧栏。
enum SettingsWindowChrome {
    static let toggleSidebar = Notification.Name("settings.toggleSidebar")
    private static let toolbarIdentifier = NSToolbar.Identifier("NemoNotchSettingsToolbar")
    private static let toggleItemIdentifier = NSToolbarItem.Identifier("NemoNotchSettingsToggleSidebar")

    /// 幂等安装。在 SettingsView.onAppear 调用;此刻窗口标题可能尚未就位
    /// (Settings 场景的窗口元数据晚于内容出现),找不到就短暂重试。
    @MainActor static func install(retries: Int = 8) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.title.hasPrefix("NemoNotch") && $0.toolbar == nil
        }) else {
            guard retries > 0 else {
                LogService.warn("Settings toolbar install gave up: window not found", category: "Settings")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                install(retries: retries - 1)
            }
            return
        }
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = Delegate.shared
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        // .unified:项与红绿灯同排(默认 .expanded 会渲染成标题下方的悬浮大圆钮)。
        window.toolbarStyle = .unified
        // 隐藏窗口标题(侧栏选中项已表明当前页),标题占位消失后,唯一的
        // 工具栏项 + flexibleSpace 把收起按钮钉在最左侧——紧挨红绿灯。
        window.titleVisibility = .hidden
        LogService.info("Settings window toolbar installed", category: "Settings")
    }

    private final class Delegate: NSObject, NSToolbarDelegate {
        @MainActor static let shared = Delegate()

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard itemIdentifier == toggleItemIdentifier else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "settings.nav.toggle_sidebar")
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: item.label)
            item.target = Target.shared
            item.action = #selector(Target.toggle)
            return item
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleItemIdentifier, .flexibleSpace]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleItemIdentifier, .flexibleSpace]
        }
    }

    private final class Target: NSObject {
        @MainActor static let shared = Target()
        @objc func toggle() {
            NotificationCenter.default.post(name: toggleSidebar, object: nil)
        }
    }
}
