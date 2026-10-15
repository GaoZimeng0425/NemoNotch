import Foundation
import Observation

/// 设置搜索的共享状态。侧栏顶部的 `SettingsSidebarSearchBar`(SwiftUI)
/// 绑定写入 `query`,侧栏在 body 里读取驱动过滤 —— `@Observable` 的读取即
/// 追踪,不需要注入环境。模型跨窗口会话存活,SettingsView 在 onAppear
/// 复位,重开窗口时搜索从空词开始。
@MainActor @Observable
final class SettingsSearchModel {
    static let shared = SettingsSearchModel()

    var query = ""

    private init() {}
}
