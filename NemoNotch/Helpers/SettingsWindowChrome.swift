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

    /// SwiftUI Settings 场景窗口的 frame autosave 名(实测常量,`NSWindow Frame
    /// com_apple_SwiftUI_Settings_window` 即由它写入)。用它认窗口是确定性的:
    /// 按标题匹配在真机上会扑空(title 在 onAppear 时未必就位),而 notch 各窗口
    /// 与它天然互斥——只有 Settings 场景窗口带这个 autosave 名。
    private static let settingsAutosaveName = "com_apple_SwiftUI_Settings_window"

    /// 幂等安装。在 SettingsView.onAppear 调用;此刻窗口的 autosave 名可能尚未
    /// 就位(场景的窗口元数据晚于内容出现),找不到就短暂重试。
    /// 窗口的默认尺寸不在这一层设——Settings 场景认 scene 级的
    /// `.defaultSize(width:height:)`(见 NemoNotchApp),不认内容根视图的
    /// ideal 值(实测 ideal 被无视、开成 900 宽)。
    @MainActor static func install(retries: Int = 8) {
        guard let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == settingsAutosaveName
        }) else {
            guard retries > 0 else {
                let dump = NSApp.windows
                    .map {
                        "\($0.frameAutosaveName.isEmpty ? "-" : $0.frameAutosaveName)|'\($0.title)'|vis=\($0.isVisible)|tb=\($0.toolbar != nil)"
                    }
                    .joined(separator: "; ")
                LogService.warn(
                    "Settings toolbar install gave up: window not found. windows=[\(dump)]",
                    category: "Settings"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                install(retries: retries - 1)
            }
            return
        }
        guard window.toolbar == nil else { return } // 本会话已装过
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = Delegate.shared
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        // .unified:项与红绿灯同排(默认 .expanded 会渲染成标题下方的悬浮大圆钮)。
        // .unifiedCompact:条尽量矮——右侧没有更多工具项,标准 unified 的
        // 高度全是空白;compact 档按钮仍在红绿灯旁。
        window.toolbarStyle = .unifiedCompact
        // 其他 App(系统设置/Finder)的样子:侧栏材质直通窗口顶,红绿灯浮
        // 在上面,没有一条横贯全宽的"带子"。这需要 fullSizeContentView +
        // 透明标题条;此前 SwiftUI ignoresSafeArea 不生效就是因为窗口没开
        // fullSizeContentView,SwiftUI 内容被挡在标题条下。
        window.styleMask.insert(.fullSizeContentView)
        // Settings 场景造的窗口天生没有 .resizable,用户无法拖拽缩放;内容的
        // frame(minWidth:minHeight:) 会以 auto-layout 约束落在 hosting view 上,
        // 拖不破版式。
        window.styleMask.insert(.resizable)
        window.titlebarAppearsTransparent = true
        // 隐藏窗口标题(侧栏选中项已表明当前页),唯一的工具栏项 +
        // flexibleSpace 把收起按钮钉在最左侧——紧挨红绿灯。
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

/// Settings 窗口的底层(凹陷层):真正的 sidebar 材质,behind-window 混合,
/// 与 Finder / 系统设置侧栏同一种半透明质感。侧栏直接画在它上面,右侧
/// 内容卡片压在它之上,卡片四周露出的一圈就是凹陷边框。
struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
