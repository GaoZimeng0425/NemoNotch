import Foundation

/// 启动参数驱动的 UI 测试/截图模式。
/// `--uitest` 打开;`--tab=<rawValue>` 指定首屏 Tab(缺省 overview)。
enum UITestMode {
    static func isActive(in args: [String]) -> Bool {
        args.contains("--uitest")
    }

    static func tab(in args: [String]) -> Tab {
        guard let raw = args.first(where: { $0.hasPrefix("--tab=") })?
            .dropFirst("--tab=".count) else { return .overview }
        return Tab(rawValue: String(raw)) ?? .overview
    }

    /// `--flash` 打开:展示一次「完成」全屏 glow + toast 并保持不衰减,供截图。
    static func flash(in args: [String]) -> Bool {
        args.contains("--flash")
    }

    /// 截图矩形落盘路径,供脚本读取后 screencapture。
    static let rectFilePath = "/tmp/nemonotch-uitest.rect"

    /// 运行时便捷入口(读真实进程参数)。
    static var isActive: Bool {
        isActive(in: ProcessInfo.processInfo.arguments)
    }

    static var tab: Tab {
        tab(in: ProcessInfo.processInfo.arguments)
    }

    static var flash: Bool {
        flash(in: ProcessInfo.processInfo.arguments)
    }
}
