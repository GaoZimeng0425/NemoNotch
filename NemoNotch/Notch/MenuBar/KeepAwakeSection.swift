import SwiftUI

/// 菜单栏里的「合盖不休眠」开关。
///
/// 切换会弹一次系统授权框(`pmset -a disablesleep` 需要 root),所以
/// `isBusy` 期间禁用,避免连点堆叠出多个授权框。
struct KeepAwakeSection: View {
    @Environment(KeepAwakeService.self) private var keepAwake

    var body: some View {
        Toggle("menu.keep_awake", isOn: Binding(
            get: { keepAwake.isEnabled },
            set: { on in Task { await keepAwake.setEnabled(on) } }
        ))
        .disabled(keepAwake.isBusy)

        // 系统里 SleepDisabled 已经是开的,但不是我们开的(用户手动跑过 pmset,
        // 或别的 App 开的)。说明一句,免得用户以为是 NemoNotch 干的。
        if keepAwake.isEnabled, !keepAwake.isOwned {
            Text("menu.keep_awake.external")
                .font(.caption)
        }

        Divider()
    }
}
